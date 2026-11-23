/* =====================================================================
   AcmeKB: functions and stored procedures
   Every tool procedure has the same signature so the agent engine can
   call it generically:  (@ArgsJson NVARCHAR(MAX), @Result NVARCHAR(MAX) OUTPUT)

   Notes on the implementation:
     - JSON input is parsed with OPENJSON ... WITH (... NVARCHAR(MAX)):
       JSON_VALUE returns NULL for strings longer than 4000 characters.
     - Text is built with CONCAT: FORMATMESSAGE truncates to 2047 characters.
     - The engine only executes tools exposed in the current turn
       (dbo.fn_IsToolAllowed); model name, Ollama URL and system prompt are
       not parameters, so API callers cannot redirect or re-prompt it.
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
GO

USE AcmeKB;
GO

/* ---------------------------------------------------------------------
   Skill catalog for the system prompt (lightweight: names + descriptions)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_GetAvailableSkills
    @SkillCatalogText NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @SkillCatalogText = STRING_AGG(
        CAST(CONCAT(N'- Skill: "', SkillName, N'" | Description: ', Description) AS NVARCHAR(MAX)),
        CHAR(10))
    FROM dbo.SkillRegistry
    WHERE IsActive = 1;

    IF @SkillCatalogText IS NULL
        SET @SkillCatalogText = N'No skills currently available.';
END;
GO

/* ---------------------------------------------------------------------
   Meta-tool: returns the tool schemas of one skill (Ollama "tools" format)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_LoadSkill
    @ArgsJson NVARCHAR(MAX),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RequestedSkill NVARCHAR(100);

    IF ISJSON(@ArgsJson) = 1
        SELECT @RequestedSkill = a.SkillName
        FROM OPENJSON(@ArgsJson) WITH (SkillName NVARCHAR(100) '$.SkillName') AS a;

    IF EXISTS (SELECT 1 FROM dbo.SkillRegistry WHERE SkillName = @RequestedSkill AND IsActive = 1)
    BEGIN
        SELECT @Result = (
            SELECT
                N'function' AS [type],
                JSON_QUERY((
                    SELECT
                        FunctionName AS [name],
                        FunctionDescription AS [description],
                        JSON_QUERY(ParametersSchemaJson) AS [parameters]
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                )) AS [function]
            FROM dbo.SkillTools
            WHERE SkillName = @RequestedSkill AND IsActive = 1
            FOR JSON PATH
        );

        IF @Result IS NULL OR @Result = N''
            SET @Result = CONCAT(N'Skill "', @RequestedSkill, N'" is active but contains no executable tools.');
    END
    ELSE
        SET @Result = CONCAT(N'Error: Skill "', @RequestedSkill, N'" not found or inactive.');
END;
GO

/* ---------------------------------------------------------------------
   Internal: insert one chunk and its embeddings (not exposed as a tool)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_AddKnowledgeChunkInternal
    @AppName NVARCHAR(100),
    @ModuleName NVARCHAR(100),
    @DocType NVARCHAR(50),
    @Breadcrumbs NVARCHAR(500) = NULL,
    @AppVersion NVARCHAR(50) = NULL,
    @EventDate DATETIME2 = NULL,
    @DocumentID NVARCHAR(100) = NULL,
    @ChunkIndex INT = 0,
    @Title NVARCHAR(255) = NULL,
    @MainContent NVARCHAR(MAX),
    @SearchContext NVARCHAR(MAX) = NULL,
    @MetadataJson NVARCHAR(MAX) = NULL,
    @InsertedChunkID BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @DocumentID = ISNULL(@DocumentID, CAST(NEWID() AS NVARCHAR(36)));
    SET @EventDate = ISNULL(@EventDate, SYSDATETIME());

    BEGIN TRANSACTION;
    BEGIN TRY
        -- 1. Text chunk
        INSERT INTO dbo.KnowledgeChunks (
            AppName, ModuleName, DocType, Breadcrumbs, AppVersion, EventDate,
            DocumentID, ChunkIndex, Title, MainContent, SearchContext, MetadataJson
        )
        VALUES (
            @AppName, @ModuleName, @DocType, @Breadcrumbs, @AppVersion, @EventDate,
            @DocumentID, @ChunkIndex, @Title, @MainContent, @SearchContext, @MetadataJson
        );

        SET @InsertedChunkID = SCOPE_IDENTITY();

        -- 2. Embedding of the main content (generated inside SQL Server)
        INSERT INTO dbo.KnowledgeEmbeddings (ChunkID, VectorType, Embedding)
        SELECT @InsertedChunkID, N'MainContent', AI_GENERATE_EMBEDDINGS(@MainContent USE MODEL MyOllamaEmbeddingModel);

        -- 3. Embedding of the search context (summary / likely questions), if any
        IF @SearchContext IS NOT NULL AND LEN(TRIM(@SearchContext)) > 0
            INSERT INTO dbo.KnowledgeEmbeddings (ChunkID, VectorType, Embedding)
            SELECT @InsertedChunkID, N'SearchContext', AI_GENERATE_EMBEDDINGS(@SearchContext USE MODEL MyOllamaEmbeddingModel);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Helper: is the tool exposed to the model in the current turn?
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_IsToolAllowed
(
    @ActiveToolsJson NVARCHAR(MAX),
    @FunctionName    NVARCHAR(128)
)
RETURNS BIT
AS
BEGIN
    IF @FunctionName IS NULL OR ISJSON(@ActiveToolsJson) <> 1
        RETURN 0;

    IF @FunctionName = N'sp_LoadSkill'
        RETURN 1;

    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@ActiveToolsJson) t
        WHERE JSON_VALUE(t.[value], '$.function.name') = @FunctionName
    )
    AND EXISTS (
        SELECT 1
        FROM dbo.SkillTools st
        JOIN dbo.SkillRegistry sr ON sr.SkillName = st.SkillName
        WHERE st.FunctionName = @FunctionName
          AND st.IsActive = 1
          AND sr.IsActive = 1
    )
        RETURN 1;

    RETURN 0;
END;
GO

/* ---------------------------------------------------------------------
   Agent engine
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_ExecuteOllamaSkillEngine
    @SessionID UNIQUEIDENTIFIER = NULL OUTPUT,
    @UserPrompt NVARCHAR(MAX),
    @EnableLogging BIT = 1,
    @MaxIterations INT = 6
AS
BEGIN
    SET NOCOUNT ON;

    -- Engine configuration (intentionally not exposed as parameters)
    DECLARE @SystemPrompt NVARCHAR(MAX) = N'You are the Acme Helpdesk knowledge assistant. Answer support questions using the knowledge base; cite ticket IDs, versions and document titles you used.';
    DECLARE @ModelName NVARCHAR(100) = N'gemma4:e4b';
    DECLARE @OllamaUrl NVARCHAR(4000) = N'https://localhost/api/chat';
    DECLARE @MaxIterationsLimit INT = 10;

    SET @MaxIterations = CASE
        WHEN @MaxIterations IS NULL OR @MaxIterations < 1 THEN 1
        WHEN @MaxIterations > @MaxIterationsLimit THEN @MaxIterationsLimit
        ELSE @MaxIterations
    END;

    IF @UserPrompt IS NULL OR LEN(TRIM(@UserPrompt)) = 0
        THROW 50000, N'UserPrompt is required.', 1;

    DECLARE @LastRole NVARCHAR(50);
    DECLARE @SkillCatalogText NVARCHAR(MAX);
    DECLARE @FullSystemPrompt NVARCHAR(MAX);
    DECLARE @ActiveToolsJson NVARCHAR(MAX);
    DECLARE @CurrentMessagesJson NVARCHAR(MAX);
    DECLARE @CurrentUserMessageID BIGINT;
    DECLARE @Counter INT = 0;
    DECLARE @HasMoreTools BIT = 1;
    DECLARE @RequestBody NVARCHAR(MAX);
    DECLARE @RestResponse NVARCHAR(MAX);
    DECLARE @RestReturnCode INT;
    DECLARE @OllamaResult NVARCHAR(MAX);
    DECLARE @FinalContent NVARCHAR(MAX) = NULL;
    DECLARE @ExecutionError NVARCHAR(MAX) = NULL;
    DECLARE @HasError BIT = 0;
    DECLARE @StartTime DATETIME2;
    DECLARE @DurationMs INT;
    DECLARE @AssistantMessage NVARCHAR(MAX);
    DECLARE @AssistantContent NVARCHAR(MAX);
    DECLARE @ToolCallsJson NVARCHAR(MAX);
    DECLARE @ThrowMessage NVARCHAR(2048);

    -- 1. Session management
    IF @SessionID IS NULL
    BEGIN
        SET @SessionID = NEWID();
        INSERT INTO dbo.ChatSessions (SessionID, Title, CreatedAt, UpdatedAt)
        VALUES (@SessionID, LEFT(@UserPrompt, 100), SYSDATETIME(), SYSDATETIME());
    END
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.ChatSessions WHERE SessionID = @SessionID)
    BEGIN
        INSERT INTO dbo.ChatSessions (SessionID, Title, CreatedAt, UpdatedAt)
        VALUES (@SessionID, LEFT(@UserPrompt, 100), SYSDATETIME(), SYSDATETIME());
    END
    ELSE
    BEGIN
        UPDATE dbo.ChatSessions SET UpdatedAt = SYSDATETIME() WHERE SessionID = @SessionID;
    END;

    -- 2. Prevent two consecutive user messages (e.g. after a failed turn)
    SELECT TOP (1) @LastRole = Role
    FROM dbo.ChatMessages
    WHERE SessionID = @SessionID
    ORDER BY MessageID DESC;

    IF @LastRole = N'user'
        INSERT INTO dbo.ChatMessages (SessionID, Role, Content, CreatedAt)
        VALUES (@SessionID, N'assistant', N'', SYSDATETIME());

    -- 3. Persist the user prompt
    INSERT INTO dbo.ChatMessages (SessionID, Role, Content, CreatedAt)
    VALUES (@SessionID, N'user', @UserPrompt, SYSDATETIME());

    SET @CurrentUserMessageID = SCOPE_IDENTITY();

    -- 4. System prompt with the skills catalog
    EXEC dbo.sp_GetAvailableSkills @SkillCatalogText = @SkillCatalogText OUTPUT;

    SET @FullSystemPrompt = CONCAT(
        @SystemPrompt, CHAR(10), CHAR(10),
        N'AVAILABLE SKILLS CATALOG:', CHAR(10), @SkillCatalogText, CHAR(10), CHAR(10),
        N'INSTRUCTIONS: You start with only the "sp_LoadSkill" tool. If you need a domain tool, invoke "sp_LoadSkill" with the appropriate SkillName to dynamically load its capabilities.');

    -- 5. Initial tool list: only the meta-tool
    SET @ActiveToolsJson = (
        SELECT
            N'function' AS [type],
            JSON_QUERY((
                SELECT
                    N'sp_LoadSkill' AS [name],
                    N'Loads and exposes tools required for a specific skill. Call this first when you need domain functionality.' AS [description],
                    JSON_QUERY(N'{ "type": "object", "properties": { "SkillName": { "type": "string", "description": "The exact name of the skill to load." } }, "required": ["SkillName"] }') AS [parameters]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            )) AS [function]
        FOR JSON PATH
    );

    -- 6. Context: system prompt + up to 3 previous clean user/assistant turns + current prompt
    ;WITH LastTurns AS (
        SELECT TOP (3) MessageID
        FROM dbo.ChatMessages
        WHERE SessionID = @SessionID
          AND Role = N'user'
          AND MessageID < @CurrentUserMessageID
        ORDER BY MessageID DESC
    ),
    HistoryMessages AS (
        SELECT M.MessageID, M.Role, M.Content
        FROM dbo.ChatMessages M
        WHERE M.SessionID = @SessionID
          AND (
              M.Role = N'user'
              OR (M.Role = N'assistant' AND (M.ToolCallsJson IS NULL OR M.ToolCallsJson = N'[]'))
          )
          AND M.MessageID >= ISNULL((SELECT MIN(MessageID) FROM LastTurns), @CurrentUserMessageID)
          AND M.MessageID < @CurrentUserMessageID
    ),
    OrderedPayload AS (
        SELECT 0 AS [PriorityGroup], CAST(0 AS BIGINT) AS [MessageID], N'system' AS [role], @FullSystemPrompt AS [content]
        UNION ALL
        SELECT 1, MessageID, Role, Content FROM HistoryMessages
        UNION ALL
        SELECT 2, @CurrentUserMessageID, N'user', @UserPrompt
    )
    SELECT @CurrentMessagesJson = (
        SELECT [role], [content]
        FROM OrderedPayload
        ORDER BY [PriorityGroup], [MessageID]
        FOR JSON PATH
    );

    -- 7. Agent loop
    WHILE @HasMoreTools = 1 AND @Counter < @MaxIterations
    BEGIN
        SET @Counter += 1;
        SET @StartTime = SYSDATETIME();
        SET @ExecutionError = NULL;
        SET @HasError = 0;
        SET @RestResponse = NULL;
        SET @OllamaResult = NULL;
        SET @AssistantMessage = NULL;
        SET @AssistantContent = NULL;
        SET @ToolCallsJson = NULL;

        SET @RequestBody = (
            SELECT
                @ModelName AS [model],
                CAST(0 AS BIT) AS [stream],
                CAST(0 AS BIT) AS [think],
                JSON_QUERY(@CurrentMessagesJson) AS [messages],
                JSON_QUERY(@ActiveToolsJson) AS [tools]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        BEGIN TRY
            EXEC @RestReturnCode = sp_invoke_external_rest_endpoint
                @url = @OllamaUrl,
                @method = N'POST',
                @headers = N'{"Content-Type": "application/json"}',
                @payload = @RequestBody,
                @timeout = 200,
                @response = @RestResponse OUTPUT;

            SET @OllamaResult = JSON_QUERY(@RestResponse, '$.result');
            SET @AssistantMessage = JSON_QUERY(@OllamaResult, '$.message');

            IF @RestReturnCode <> 0
                SET @ExecutionError = CONCAT(N'Ollama returned an error (code ', @RestReturnCode, N'): ', LEFT(@RestResponse, 1000));
            ELSE IF @AssistantMessage IS NULL
                SET @ExecutionError = CONCAT(N'Unexpected Ollama response: ', LEFT(@RestResponse, 1000));

            IF @ExecutionError IS NOT NULL
                SET @HasError = 1;
        END TRY
        BEGIN CATCH
            SET @HasError = 1;
            SET @ExecutionError = ERROR_MESSAGE();
        END CATCH;

        SET @DurationMs = DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME());

        IF @EnableLogging = 1
            INSERT INTO dbo.OllamaLogs (
                SessionID, StepNumber, ModelName, RequestPayload, ResponsePayload, ExecutionTimeMs, HasError, ErrorMessage, CreatedAt
            )
            VALUES (
                @SessionID, @Counter, @ModelName, @RequestBody, @RestResponse, @DurationMs, @HasError, @ExecutionError, SYSDATETIME()
            );

        IF @HasError = 1
        BEGIN
            SET @ThrowMessage = LEFT(@ExecutionError, 2048);
            THROW 50001, @ThrowMessage, 1;
        END;

        -- OPENJSON ... WITH nvarchar(max): JSON_VALUE returns NULL above 4000 chars
        SELECT
            @AssistantContent = m.content,
            @ToolCallsJson = m.tool_calls
        FROM OPENJSON(@AssistantMessage)
        WITH (
            content NVARCHAR(MAX) '$.content',
            tool_calls NVARCHAR(MAX) '$.tool_calls' AS JSON
        ) AS m;

        SET @CurrentMessagesJson = JSON_MODIFY(@CurrentMessagesJson, 'append $', JSON_QUERY(@AssistantMessage));

        INSERT INTO dbo.ChatMessages (SessionID, Role, Content, ToolCallsJson, CreatedAt)
        VALUES (@SessionID, N'assistant', @AssistantContent, @ToolCallsJson, SYSDATETIME());

        IF @ToolCallsJson IS NOT NULL AND @ToolCallsJson <> N'[]'
        BEGIN
            DECLARE @CurrentToolCall NVARCHAR(MAX);

            DECLARE tool_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT [value] FROM OPENJSON(@ToolCallsJson);

            OPEN tool_cursor;
            FETCH NEXT FROM tool_cursor INTO @CurrentToolCall;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @FunctionName NVARCHAR(128) = JSON_VALUE(@CurrentToolCall, '$.function.name');
                DECLARE @ArgumentsJson NVARCHAR(MAX) = JSON_QUERY(@CurrentToolCall, '$.function.arguments');
                DECLARE @ExecutionResult NVARCHAR(MAX) = N'';

                IF dbo.fn_IsToolAllowed(@ActiveToolsJson, @FunctionName) = 0
                BEGIN
                    SET @ExecutionResult = CONCAT(
                        N'Error: tool "', @FunctionName,
                        N'" is not available. Load the corresponding skill with sp_LoadSkill first.');
                END
                ELSE IF @FunctionName = N'sp_LoadSkill'
                BEGIN
                    EXEC dbo.sp_LoadSkill @ArgsJson = @ArgumentsJson, @Result = @ExecutionResult OUTPUT;

                    IF ISJSON(@ExecutionResult) > 0
                    BEGIN
                        SELECT @ActiveToolsJson = (
                            SELECT
                                JSON_VALUE(T.value, '$.type') AS [type],
                                JSON_QUERY(T.value, '$.function') AS [function]
                            FROM (
                                SELECT value FROM OPENJSON(@ActiveToolsJson)
                                UNION
                                SELECT value FROM OPENJSON(@ExecutionResult)
                            ) AS T
                            FOR JSON PATH
                        );

                        SET @ExecutionResult = N'Skill loaded successfully. New tools are now available in context.';
                    END;
                END
                ELSE
                BEGIN
                    DECLARE @Sql NVARCHAR(MAX) = N'EXEC dbo.' + QUOTENAME(@FunctionName) + N' @ArgsJson = @Args, @Result = @Res OUTPUT;';

                    BEGIN TRY
                        EXEC sp_executesql
                            @stmt = @Sql,
                            @params = N'@Args NVARCHAR(MAX), @Res NVARCHAR(MAX) OUTPUT',
                            @Args = @ArgumentsJson,
                            @Res = @ExecutionResult OUTPUT;
                    END TRY
                    BEGIN CATCH
                        SET @ExecutionResult = CONCAT(N'Error executing ', @FunctionName, N': ', ERROR_MESSAGE());
                    END CATCH;
                END;

                DECLARE @ToolMessage NVARCHAR(MAX) = (
                    SELECT N'tool' AS [role], @FunctionName AS [tool_name], @ExecutionResult AS [content]
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
                );

                SET @CurrentMessagesJson = JSON_MODIFY(@CurrentMessagesJson, 'append $', JSON_QUERY(@ToolMessage));

                INSERT INTO dbo.ChatMessages (SessionID, Role, Content, CreatedAt)
                VALUES (@SessionID, N'tool', @ExecutionResult, SYSDATETIME());

                FETCH NEXT FROM tool_cursor INTO @CurrentToolCall;
            END;

            CLOSE tool_cursor;
            DEALLOCATE tool_cursor;
        END
        ELSE
        BEGIN
            SET @HasMoreTools = 0;
            SET @FinalContent = @AssistantContent;
        END;
    END;

    -- Iteration limit reached while the model still wanted tools
    IF @HasMoreTools = 1
    BEGIN
        SET @FinalContent = CONCAT(
            N'The assistant reached the maximum number of tool steps (', @MaxIterations,
            N') without producing a final answer. Please rephrase or narrow down the question.');

        INSERT INTO dbo.ChatMessages (SessionID, Role, Content, CreatedAt)
        VALUES (@SessionID, N'assistant', @FinalContent, SYSDATETIME());
    END;

    SELECT
        @SessionID AS [SessionID],
        @FinalContent AS [FinalResponse],
        @Counter AS [TotalStepsExecuted];
END;
GO

/* ---------------------------------------------------------------------
   Hybrid search (vector + full-text, RRF)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_SearchKnowledgeBase
    @ArgsJson NVARCHAR(MAX),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @QueryText NVARCHAR(MAX);
    DECLARE @AppName NVARCHAR(100);
    DECLARE @DocType NVARCHAR(50);
    DECLARE @TopNText NVARCHAR(50);
    DECLARE @MinSimilarityText NVARCHAR(50);
    DECLARE @RRF_K INT = 60;

    IF ISJSON(@ArgsJson) <> 1
    BEGIN
        SET @Result = N'Error: arguments must be a JSON object.';
        RETURN;
    END;

    SELECT
        @QueryText = a.QueryText,
        @AppName = NULLIF(TRIM(a.AppName), N''),
        @DocType = NULLIF(TRIM(a.DocType), N''),
        @TopNText = a.TopN,
        @MinSimilarityText = a.MinSimilarity
    FROM OPENJSON(@ArgsJson)
    WITH (
        QueryText NVARCHAR(MAX) '$.QueryText',
        AppName NVARCHAR(100) '$.AppName',
        DocType NVARCHAR(50) '$.DocType',
        TopN NVARCHAR(50) '$.TopN',
        MinSimilarity NVARCHAR(50) '$.MinSimilarity'
    ) AS a;

    DECLARE @TopN INT = ISNULL(TRY_CAST(@TopNText AS INT), 5);
    SET @TopN = CASE WHEN @TopN < 1 THEN 1 WHEN @TopN > 20 THEN 20 ELSE @TopN END;

    DECLARE @MinSimilarity FLOAT = ISNULL(TRY_CAST(@MinSimilarityText AS FLOAT), 0.5);
    SET @MinSimilarity = CASE WHEN @MinSimilarity < 0 THEN 0 WHEN @MinSimilarity > 1 THEN 1 ELSE @MinSimilarity END;

    DECLARE @CandidateCount INT = @TopN * 3;

    IF @QueryText IS NULL OR LEN(TRIM(@QueryText)) = 0
    BEGIN
        SET @Result = N'Error: QueryText parameter is required for search.';
        RETURN;
    END;

    -- FREETEXTTABLE: free-form text, OR semantics, inflectional forms; no syntax to escape
    DECLARE @FtsQuery NVARCHAR(4000) = LEFT(TRIM(@QueryText), 4000);

    BEGIN TRY
        DECLARE @QueryEmbedding VECTOR(1024);
        SELECT @QueryEmbedding = AI_GENERATE_EMBEDDINGS(@QueryText USE MODEL MyOllamaEmbeddingModel);

        WITH
        -- A. Vector search: best distance per chunk (MainContent / SearchContext vectors)
        VectorCandidates AS (
            SELECT TOP (@CandidateCount)
                ke.ChunkID,
                MIN(VECTOR_DISTANCE('cosine', ke.Embedding, @QueryEmbedding)) AS BestDistance
            FROM dbo.KnowledgeEmbeddings ke
            INNER JOIN dbo.KnowledgeChunks kc ON kc.ChunkID = ke.ChunkID
            WHERE (@AppName IS NULL OR kc.AppName = @AppName)
              AND (@DocType IS NULL OR kc.DocType = @DocType)
            GROUP BY ke.ChunkID
            HAVING 1.0 - MIN(VECTOR_DISTANCE('cosine', ke.Embedding, @QueryEmbedding)) >= @MinSimilarity
            ORDER BY BestDistance ASC
        ),
        VectorRanked AS (
            SELECT
                ChunkID,
                1.0 - BestDistance AS BestVectorScore,
                ROW_NUMBER() OVER (ORDER BY BestDistance ASC) AS VectorRank
            FROM VectorCandidates
        ),
        -- B. Full-text search
        FullTextCandidates AS (
            SELECT TOP (@CandidateCount)
                ft.[KEY] AS ChunkID,
                ft.[RANK] AS FTSRankScore
            FROM FREETEXTTABLE(dbo.KnowledgeChunks, (Title, MainContent, SearchContext), @FtsQuery) ft
            INNER JOIN dbo.KnowledgeChunks kc ON kc.ChunkID = ft.[KEY]
            WHERE (@AppName IS NULL OR kc.AppName = @AppName)
              AND (@DocType IS NULL OR kc.DocType = @DocType)
            ORDER BY ft.[RANK] DESC
        ),
        FullTextRanked AS (
            SELECT
                ChunkID,
                FTSRankScore,
                ROW_NUMBER() OVER (ORDER BY FTSRankScore DESC) AS FTSRank
            FROM FullTextCandidates
        ),
        -- C. Reciprocal Rank Fusion
        CombinedKeys AS (
            SELECT ChunkID FROM VectorRanked
            UNION
            SELECT ChunkID FROM FullTextRanked
        ),
        RRF_Calculation AS (
            SELECT
                ck.ChunkID,
                v.VectorRank,
                v.BestVectorScore,
                f.FTSRank,
                ISNULL(1.0 / (@RRF_K + v.VectorRank), 0.0) + ISNULL(1.0 / (@RRF_K + f.FTSRank), 0.0) AS RRF_Score
            FROM CombinedKeys ck
            LEFT JOIN VectorRanked v ON v.ChunkID = ck.ChunkID
            LEFT JOIN FullTextRanked f ON f.ChunkID = ck.ChunkID
        )
        SELECT @Result = (
            SELECT TOP (@TopN)
                kc.ChunkID,
                kc.AppName,
                kc.ModuleName,
                kc.DocType,
                kc.AppVersion,
                kc.Title,
                kc.MainContent,
                kc.Breadcrumbs,
                ROUND(rrf.RRF_Score, 6) AS RRFScore,
                rrf.VectorRank,
                rrf.FTSRank,
                ROUND(rrf.BestVectorScore, 4) AS VectorSimilarity
            FROM RRF_Calculation rrf
            INNER JOIN dbo.KnowledgeChunks kc ON kc.ChunkID = rrf.ChunkID
            ORDER BY rrf.RRF_Score DESC, rrf.ChunkID DESC
            FOR JSON PATH
        );

        IF @Result IS NULL
            SET @Result = N'[]';
    END TRY
    BEGIN CATCH
        SET @Result = CONCAT(N'Error executing hybrid search: ', ERROR_MESSAGE());
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Helpdesk ticket ingest
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_AddHelpdeskTicket
    @ArgsJson NVARCHAR(MAX),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@ArgsJson) <> 1
    BEGIN
        SET @Result = N'Error: arguments must be a JSON object.';
        RETURN;
    END;

    DECLARE @AppName NVARCHAR(100), @ModuleName NVARCHAR(100), @TicketID NVARCHAR(100), @Title NVARCHAR(255),
            @ProblemDescription NVARCHAR(MAX), @SolutionDescription NVARCHAR(MAX), @HypotheticalQuestions NVARCHAR(MAX);

    SELECT
        @AppName = a.AppName,
        @ModuleName = a.ModuleName,
        @TicketID = a.TicketID,
        @Title = a.IssueTitle,
        @ProblemDescription = a.ProblemDescription,
        @SolutionDescription = a.SolutionDescription,
        @HypotheticalQuestions = a.HypotheticalQuestions
    FROM OPENJSON(@ArgsJson)
    WITH (
        AppName NVARCHAR(100) '$.AppName',
        ModuleName NVARCHAR(100) '$.ModuleName',
        TicketID NVARCHAR(100) '$.TicketID',
        IssueTitle NVARCHAR(255) '$.IssueTitle',
        ProblemDescription NVARCHAR(MAX) '$.ProblemDescription',
        SolutionDescription NVARCHAR(MAX) '$.SolutionDescription',
        HypotheticalQuestions NVARCHAR(MAX) '$.HypotheticalQuestions'
    ) AS a;

    IF @AppName IS NULL OR @ModuleName IS NULL OR @ProblemDescription IS NULL OR @SolutionDescription IS NULL
    BEGIN
        SET @Result = N'Error: Missing required fields for Helpdesk Ticket (AppName, ModuleName, ProblemDescription, SolutionDescription).';
        RETURN;
    END;

    -- CONCAT instead of FORMATMESSAGE: FORMATMESSAGE truncates its output to 2047 characters
    DECLARE @MainContent NVARCHAR(MAX) = CONCAT(
        N'### ISSUE / PROBLEM:', CHAR(10), @ProblemDescription, CHAR(10), CHAR(10),
        N'### SOLUTION / RESOLUTION:', CHAR(10), @SolutionDescription);

    DECLARE @SearchContext NVARCHAR(MAX) = CONCAT(
        N'Problem Summary: ', @ProblemDescription, CHAR(10),
        N'User Questions / Symptoms: ', ISNULL(@HypotheticalQuestions, N'N/A'));

    DECLARE @ChunkID BIGINT;

    BEGIN TRY
        EXEC dbo.sp_AddKnowledgeChunkInternal
            @AppName = @AppName,
            @ModuleName = @ModuleName,
            @DocType = N'HelpdeskTicket',
            @Breadcrumbs = N'Helpdesk > Tickets',
            @DocumentID = @TicketID,
            @Title = @Title,
            @MainContent = @MainContent,
            @SearchContext = @SearchContext,
            @InsertedChunkID = @ChunkID OUTPUT;

        SET @Result = CONCAT(N'Helpdesk ticket successfully recorded. ChunkID: ', @ChunkID);
    END TRY
    BEGIN CATCH
        SET @Result = CONCAT(N'Error adding helpdesk ticket: ', ERROR_MESSAGE());
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Release note ingest
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_AddReleaseNote
    @ArgsJson NVARCHAR(MAX),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@ArgsJson) <> 1
    BEGIN
        SET @Result = N'Error: arguments must be a JSON object.';
        RETURN;
    END;

    DECLARE @AppName NVARCHAR(100), @ModuleName NVARCHAR(100), @AppVersion NVARCHAR(50), @EventDate DATETIME2,
            @Title NVARCHAR(255), @MainContent NVARCHAR(MAX), @Summary NVARCHAR(MAX);

    SELECT
        @AppName = a.AppName,
        @ModuleName = a.ModuleName,
        @AppVersion = a.AppVersion,
        @EventDate = TRY_CAST(a.ReleaseDate AS DATETIME2),
        @Title = a.Title,
        @MainContent = a.ReleaseNotesContent,
        @Summary = a.KeyHighlights
    FROM OPENJSON(@ArgsJson)
    WITH (
        AppName NVARCHAR(100) '$.AppName',
        ModuleName NVARCHAR(100) '$.ModuleName',
        AppVersion NVARCHAR(50) '$.AppVersion',
        ReleaseDate NVARCHAR(50) '$.ReleaseDate',
        Title NVARCHAR(255) '$.Title',
        ReleaseNotesContent NVARCHAR(MAX) '$.ReleaseNotesContent',
        KeyHighlights NVARCHAR(MAX) '$.KeyHighlights'
    ) AS a;

    IF @AppName IS NULL OR @ModuleName IS NULL OR @AppVersion IS NULL OR @MainContent IS NULL
    BEGIN
        SET @Result = N'Error: Missing required fields for Release Note (AppName, ModuleName, AppVersion, ReleaseNotesContent).';
        RETURN;
    END;

    IF @Title IS NULL
        SET @Title = CONCAT(@AppName, N' v', @AppVersion, N' Release Notes');

    DECLARE @SearchContext NVARCHAR(MAX) = CONCAT(
        N'Release version: ', @AppVersion, N'. Title: ', @Title, N'. Highlights: ', ISNULL(@Summary, N'N/A'));

    DECLARE @ChunkID BIGINT;

    BEGIN TRY
        EXEC dbo.sp_AddKnowledgeChunkInternal
            @AppName = @AppName,
            @ModuleName = @ModuleName,
            @DocType = N'ReleaseNote',
            @Breadcrumbs = N'Releases',
            @AppVersion = @AppVersion,
            @EventDate = @EventDate,
            @Title = @Title,
            @MainContent = @MainContent,
            @SearchContext = @SearchContext,
            @InsertedChunkID = @ChunkID OUTPUT;

        SET @Result = CONCAT(N'Release Note for ', @AppName, N' v', @AppVersion, N' added successfully. ChunkID: ', @ChunkID);
    END TRY
    BEGIN CATCH
        SET @Result = CONCAT(N'Error adding release note: ', ERROR_MESSAGE());
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Technical document ingest (replace-by-DocID)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_AddTechnicalDoc
    @ArgsJson NVARCHAR(MAX),
    @Result NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF ISJSON(@ArgsJson) <> 1
    BEGIN
        SET @Result = N'Error: arguments must be a JSON object.';
        RETURN;
    END;

    DECLARE @DocID NVARCHAR(100), @AppName NVARCHAR(100), @ModuleName NVARCHAR(100), @DocType NVARCHAR(50),
            @AppVersion NVARCHAR(50), @DocumentTitle NVARCHAR(255), @ChunksJson NVARCHAR(MAX);

    SELECT
        @DocID = NULLIF(TRIM(a.DocID), N''),
        @AppName = NULLIF(TRIM(a.AppName), N''),
        @ModuleName = ISNULL(NULLIF(TRIM(a.ModuleName), N''), N'General'),
        @DocType = ISNULL(NULLIF(TRIM(a.DocType), N''), N'TechnicalDoc'),
        @AppVersion = a.AppVersion,
        @DocumentTitle = NULLIF(TRIM(a.DocumentTitle), N''),
        @ChunksJson = a.Chunks
    FROM OPENJSON(@ArgsJson)
    WITH (
        DocID NVARCHAR(100) '$.DocID',
        AppName NVARCHAR(100) '$.AppName',
        ModuleName NVARCHAR(100) '$.ModuleName',
        DocType NVARCHAR(50) '$.DocType',
        AppVersion NVARCHAR(50) '$.AppVersion',
        DocumentTitle NVARCHAR(255) '$.DocumentTitle',
        Chunks NVARCHAR(MAX) '$.Chunks' AS JSON
    ) AS a;

    IF @DocID IS NULL OR @AppName IS NULL OR @DocumentTitle IS NULL OR @ChunksJson IS NULL
    BEGIN
        SET @Result = N'Error: DocID, AppName, DocumentTitle, and Chunks array are required.';
        RETURN;
    END;

    DECLARE @InsertedChunks TABLE (
        ChunkID BIGINT NOT NULL,
        MainContent NVARCHAR(MAX) NOT NULL,
        SearchContext NVARCHAR(MAX) NULL
    );

    BEGIN TRANSACTION;

    BEGIN TRY
        -- 1. Replace previous version of the same document (embeddings cascade via FK)
        DELETE FROM dbo.KnowledgeChunks
        WHERE AppName = @AppName
          AND DocumentID = @DocID;

        -- 2. Insert chunks
        INSERT INTO dbo.KnowledgeChunks (
            AppName, ModuleName, DocType, AppVersion, EventDate,
            DocumentID, ChunkIndex, Title, MainContent, SearchContext, Breadcrumbs
        )
        OUTPUT inserted.ChunkID, inserted.MainContent, inserted.SearchContext
        INTO @InsertedChunks (ChunkID, MainContent, SearchContext)
        SELECT
            @AppName,
            @ModuleName,
            @DocType,
            @AppVersion,
            SYSDATETIME(),
            @DocID,
            CAST(c.[key] AS INT),
            ISNULL(NULLIF(TRIM(ch.Title), N''), @DocumentTitle),
            ch.MainContent,
            NULLIF(TRIM(ch.SearchContext), N''),
            CASE
                WHEN NULLIF(TRIM(ch.Breadcrumbs), N'') IS NOT NULL THEN LEFT(CONCAT(@DocumentTitle, N' > ', ch.Breadcrumbs), 500)
                ELSE @DocumentTitle
            END
        FROM OPENJSON(@ChunksJson) c
        CROSS APPLY OPENJSON(c.[value])
        WITH (
            Title NVARCHAR(255) '$.Title',
            MainContent NVARCHAR(MAX) '$.MainContent',
            SearchContext NVARCHAR(MAX) '$.SearchContext',
            Breadcrumbs NVARCHAR(500) '$.Breadcrumbs'
        ) AS ch
        WHERE NULLIF(TRIM(ch.MainContent), N'') IS NOT NULL;

        -- 3. Embeddings (same layout as sp_AddKnowledgeChunkInternal)
        INSERT INTO dbo.KnowledgeEmbeddings (ChunkID, VectorType, Embedding)
        SELECT ic.ChunkID, N'MainContent', AI_GENERATE_EMBEDDINGS(ic.MainContent USE MODEL MyOllamaEmbeddingModel)
        FROM @InsertedChunks ic;

        INSERT INTO dbo.KnowledgeEmbeddings (ChunkID, VectorType, Embedding)
        SELECT ic.ChunkID, N'SearchContext', AI_GENERATE_EMBEDDINGS(ic.SearchContext USE MODEL MyOllamaEmbeddingModel)
        FROM @InsertedChunks ic
        WHERE ic.SearchContext IS NOT NULL;

        COMMIT TRANSACTION;

        SET @Result = (
            SELECT
                @DocID AS DocID,
                @AppName AS AppName,
                (SELECT COUNT(*) FROM @InsertedChunks) AS ChunksProcessed,
                N'Success' AS Status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @Result = CONCAT(N'Error adding technical document: ', ERROR_MESSAGE());
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Grants for the API role (created in 01_schema.sql)
   The engine runs tools via sp_executesql, so the caller needs EXECUTE on
   every tool procedure, not only on the engine.
   --------------------------------------------------------------------- */
GRANT EXECUTE ON dbo.sp_ExecuteOllamaSkillEngine TO acmekb_api;
GRANT EXECUTE ON dbo.sp_LoadSkill TO acmekb_api;
GRANT EXECUTE ON dbo.sp_SearchKnowledgeBase TO acmekb_api;
GRANT EXECUTE ON dbo.sp_AddHelpdeskTicket TO acmekb_api;
GRANT EXECUTE ON dbo.sp_AddReleaseNote TO acmekb_api;
GRANT EXECUTE ON dbo.sp_AddTechnicalDoc TO acmekb_api;
GO

PRINT N'AcmeKB procedures ready.';
GO
