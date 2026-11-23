/* =====================================================================
   AcmeKB: end-to-end engine test against the real Ollama chat model.
   Slow (tens of seconds per prompt). Test sessions and their logs are
   deleted at the end. Model answers vary; the checks are structural.
   ===================================================================== */
:on error exit
USE AcmeKB;
SET NOCOUNT ON;

DECLARE @s1 UNIQUEIDENTIFIER, @s2 UNIQUEIDENTIFIER, @t0 DATETIME2 = SYSDATETIME(), @ms1 INT, @ms2 INT;
DECLARE @res TABLE (SessionID UNIQUEIDENTIFIER, FinalResponse NVARCHAR(MAX), TotalStepsExecuted INT);

-- E1: full agent loop (sp_LoadSkill -> sp_SearchKnowledgeBase -> final answer)
INSERT @res
EXEC dbo.sp_ExecuteOllamaSkillEngine
    @SessionID = @s1 OUTPUT,
    @UserPrompt = N'Customers stopped receiving notification emails after we upgraded Acme Helpdesk to 4.2. Search the knowledge base and give the fix.';
SET @ms1 = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

-- E2: iteration limit reached -> explicit message instead of NULL
SET @t0 = SYSDATETIME();
INSERT @res
EXEC dbo.sp_ExecuteOllamaSkillEngine
    @SessionID = @s2 OUTPUT,
    @UserPrompt = N'Search the knowledge base for the Acme Helpdesk 4.2.1 release notes and summarize them.',
    @MaxIterations = 1;
SET @ms2 = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

DECLARE @searched BIT = IIF(EXISTS (SELECT 1 FROM dbo.ChatMessages WHERE SessionID = @s1 AND ToolCallsJson LIKE N'%sp_SearchKnowledgeBase%'), 1, 0);
DECLARE @final1 NVARCHAR(MAX) = (SELECT FinalResponse FROM @res WHERE SessionID = @s1);
DECLARE @final2 NVARCHAR(MAX) = (SELECT FinalResponse FROM @res WHERE SessionID = @s2);

SELECT CAST(CONCAT(
    IIF(@searched = 1 AND LEN(@final1) > 0, N'PASS', N'FAIL'), N' E1 agent loop: loaded skill, searched, answered (', @ms1, N' ms)', CHAR(10),
    (SELECT STRING_AGG(CAST(CONCAT(N'     ', Role, N': ', LEFT(ISNULL(Content, N'<null>'), 600),
            IIF(ToolCallsJson IS NOT NULL, CONCAT(N' | tool_calls=', LEFT(ToolCallsJson, 300)), N'')) AS NVARCHAR(MAX)), CHAR(10))
            WITHIN GROUP (ORDER BY MessageID)
     FROM dbo.ChatMessages WHERE SessionID = @s1), CHAR(10),
    N'     logs: ', (SELECT STRING_AGG(CONCAT(N'step', StepNumber, N' ', ExecutionTimeMs, N'ms err=', HasError), N', ') FROM dbo.OllamaLogs WHERE SessionID = @s1), CHAR(10),
    IIF(@final2 LIKE N'The assistant reached the maximum number of tool steps%', N'PASS', N'FAIL'), N' E2 iteration limit gives an explicit message (', @ms2, N' ms)', CHAR(10),
    N'     ', @final2) AS NVARCHAR(MAX)) AS Result;

-- cleanup (ChatMessages cascade)
DELETE FROM dbo.OllamaLogs WHERE SessionID IN (@s1, @s2);
DELETE FROM dbo.ChatSessions WHERE SessionID IN (@s1, @s2);

IF NOT (@searched = 1 AND LEN(@final1) > 0 AND @final2 LIKE N'The assistant reached the maximum number of tool steps%')
    THROW 50300, N'AcmeKB engine test failed.', 1;
GO
