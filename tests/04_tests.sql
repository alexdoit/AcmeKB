/* =====================================================================
   AcmeKB: procedure tests. Writes are rolled back.
   Needs the seed data (03_seed.sql) and the embedding model online.
   Output: one PASS/FAIL line per test; the batch fails if any test fails.
   ===================================================================== */
:on error exit
USE AcmeKB;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @log TABLE (id INT IDENTITY, test NVARCHAR(200), ok BIT, detail NVARCHAR(MAX));
DECLARE @r NVARCHAR(MAX), @args NVARCHAR(MAX), @n INT, @len INT, @emb NVARCHAR(400);
DECLARE @long NVARCHAR(MAX) = REPLICATE(CAST(N'Long documentation section about webhook delivery and retry policy. ' AS NVARCHAR(MAX)), 90);

BEGIN TRAN;

/* ---------- T1: sp_AddTechnicalDoc, long chunk, no ModuleName ---------- */
SET @args = (
    SELECT N'TEST-DOC-1' AS DocID, N'ZZTestApp' AS AppName, N'Integration Guide' AS DocumentTitle,
           JSON_QUERY((SELECT * FROM (VALUES
                (N'Intro', CAST(N'Short intro about webhook integration' AS NVARCHAR(MAX)), N'webhook intro keywords', N'Chapter 1'),
                (N'Retries', @long, NULL, N'Chapter 2')
           ) v(Title, MainContent, SearchContext, Breadcrumbs) FOR JSON PATH)) AS Chunks
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_AddTechnicalDoc @ArgsJson = @args, @Result = @r OUTPUT;
SELECT @n = COUNT(*), @len = MAX(LEN(MainContent)) FROM dbo.KnowledgeChunks WHERE DocumentID = N'TEST-DOC-1';
SELECT @emb = STRING_AGG(x, N',') FROM (SELECT CONCAT(e.VectorType, N':', COUNT(*)) x FROM dbo.KnowledgeEmbeddings e JOIN dbo.KnowledgeChunks k ON k.ChunkID = e.ChunkID WHERE k.DocumentID = N'TEST-DOC-1' GROUP BY e.VectorType) q;
INSERT @log VALUES (N'T1 AddTechnicalDoc: 2 chunks, long chunk kept, 3 embeddings',
    IIF(@n = 2 AND @len > 6000 AND @emb LIKE N'%MainContent:2%' AND @emb LIKE N'%SearchContext:1%', 1, 0),
    CONCAT(@r, N' | chunks=', @n, N' maxLen=', @len, N' emb=', @emb,
           N' | module=', (SELECT TOP 1 ModuleName FROM dbo.KnowledgeChunks WHERE DocumentID = N'TEST-DOC-1')));

/* ---------- T2: re-ingest replaces by DocID, similar title untouched ---------- */
SET @args = (
    SELECT N'TEST-DOC-2' AS DocID, N'ZZTestApp' AS AppName, N'Integration Guide Extended' AS DocumentTitle,
           JSON_QUERY(N'[{"MainContent":"Extended guide content"}]') AS Chunks
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_AddTechnicalDoc @ArgsJson = @args, @Result = @r OUTPUT;

SET @args = (
    SELECT N'TEST-DOC-1' AS DocID, N'ZZTestApp' AS AppName, N'Integration Guide' AS DocumentTitle,
           JSON_QUERY(N'[{"Title":"Intro v2","MainContent":"Updated intro"}]') AS Chunks
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_AddTechnicalDoc @ArgsJson = @args, @Result = @r OUTPUT;

INSERT @log SELECT N'T2 Re-ingest DOC-1 replaces only DOC-1, DOC-2 survives',
    IIF(d1 = 1 AND d2 = 1 AND t1 = N'Intro v2', 1, 0),
    CONCAT(N'doc1=', d1, N' doc2=', d2, N' doc1title=', t1, N' | ', @r)
FROM (SELECT
        (SELECT COUNT(*) FROM dbo.KnowledgeChunks WHERE DocumentID = N'TEST-DOC-1') d1,
        (SELECT COUNT(*) FROM dbo.KnowledgeChunks WHERE DocumentID = N'TEST-DOC-2') d2,
        (SELECT MAX(Title) FROM dbo.KnowledgeChunks WHERE DocumentID = N'TEST-DOC-1') t1) q;

/* ---------- T3: helpdesk ticket with > 4000 chars (JSON_VALUE / FORMATMESSAGE limits) ---------- */
SET @args = (
    SELECT N'ZZTestApp' AS AppName, N'Core' AS ModuleName, N'TCK-TEST-1' AS TicketID, N'Long ticket' AS IssueTitle,
           @long AS ProblemDescription, N'Restart the service.' AS SolutionDescription
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_AddHelpdeskTicket @ArgsJson = @args, @Result = @r OUTPUT;
SELECT @len = MAX(LEN(MainContent)) FROM dbo.KnowledgeChunks WHERE DocumentID = N'TCK-TEST-1';
INSERT @log VALUES (N'T3 AddHelpdeskTicket: long problem not rejected/truncated',
    IIF(@r LIKE N'Helpdesk ticket successfully recorded%' AND @len > LEN(@long), 1, 0),
    CONCAT(@r, N' | storedLen=', @len, N' inputLen=', LEN(@long)));

/* ---------- T4: release note with > 4000 chars ---------- */
SET @args = (
    SELECT N'ZZTestApp' AS AppName, N'Core' AS ModuleName, N'9.9.9' AS AppVersion, N'2026-11-14' AS ReleaseDate,
           @long AS ReleaseNotesContent
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_AddReleaseNote @ArgsJson = @args, @Result = @r OUTPUT;
SELECT @len = MAX(LEN(MainContent)) FROM dbo.KnowledgeChunks WHERE AppName = N'ZZTestApp' AND DocType = N'ReleaseNote';
INSERT @log VALUES (N'T4 AddReleaseNote: long content accepted, default title',
    IIF(@r LIKE N'Release Note for ZZTestApp v9.9.9 added successfully%' AND @len = LEN(@long), 1, 0),
    CONCAT(@r, N' | storedLen=', @len, N' title=', (SELECT MAX(Title) FROM dbo.KnowledgeChunks WHERE AppName = N'ZZTestApp' AND DocType = N'ReleaseNote')));

/* ---------- T5: tool whitelist ---------- */
DECLARE @tools0 NVARCHAR(MAX) = N'[{"type":"function","function":{"name":"sp_LoadSkill"}}]';
DECLARE @tools1 NVARCHAR(MAX) = N'[{"type":"function","function":{"name":"sp_LoadSkill"}},{"type":"function","function":{"name":"sp_SearchKnowledgeBase"}}]';
INSERT @log SELECT N'T5 fn_IsToolAllowed',
    IIF(a = 0 AND b = 1 AND c = 1 AND d = 0 AND e = 0 AND f = 0, 1, 0),
    CONCAT(N'notLoaded(AddTechnicalDoc)=', a, N' loaded(Search)=', b, N' LoadSkill=', c,
           N' Engine=', d, N' NULL=', e, N' notInSkillTools(AddKnowledgeChunkInternal)=', f)
FROM (SELECT
        dbo.fn_IsToolAllowed(@tools0, N'sp_AddTechnicalDoc') a,
        dbo.fn_IsToolAllowed(@tools1, N'sp_SearchKnowledgeBase') b,
        dbo.fn_IsToolAllowed(@tools0, N'sp_LoadSkill') c,
        dbo.fn_IsToolAllowed(@tools1, N'sp_ExecuteOllamaSkillEngine') d,
        dbo.fn_IsToolAllowed(@tools1, NULL) e,
        dbo.fn_IsToolAllowed(N'[{"type":"function","function":{"name":"sp_AddKnowledgeChunkInternal"}}]', N'sp_AddKnowledgeChunkInternal') f) q;

/* ---------- T6: sp_LoadSkill returns tool schemas / error for unknown skill ---------- */
DECLARE @r2 NVARCHAR(MAX);
EXEC dbo.sp_LoadSkill @ArgsJson = N'{"SkillName":"KnowledgeSearch"}', @Result = @r OUTPUT;
EXEC dbo.sp_LoadSkill @ArgsJson = N'{"SkillName":"NoSuchSkill"}', @Result = @r2 OUTPUT;
INSERT @log VALUES (N'T6 LoadSkill: schema JSON for a known skill, error for unknown',
    IIF(ISJSON(@r) = 1 AND JSON_VALUE(@r, '$[0].function.name') = N'sp_SearchKnowledgeBase' AND @r2 LIKE N'Error:%', 1, 0),
    CONCAT(LEFT(@r, 120), N' | ', @r2));

/* ---------- T7: least-privilege API role ---------- */
CREATE USER acmekb_role_test WITHOUT LOGIN;
ALTER ROLE acmekb_api ADD MEMBER acmekb_role_test;
DECLARE @canSearch BIT = 0, @canRead BIT = 0, @deleteDenied BIT = 0, @logsDenied BIT = 0, @roleErr NVARCHAR(MAX) = N'';
EXECUTE AS USER = N'acmekb_role_test';
    BEGIN TRY
        EXEC dbo.sp_SearchKnowledgeBase @ArgsJson = N'{"QueryText":"webhook signature","TopN":1,"MinSimilarity":0}', @Result = @r OUTPUT;
        SET @canSearch = IIF(ISJSON(@r) = 1, 1, 0);
        IF @canSearch = 0 SET @roleErr += CONCAT(N'search: ', @r, N' ');
    END TRY
    BEGIN CATCH SET @roleErr += CONCAT(N'search: ', ERROR_MESSAGE(), N' '); END CATCH;
    BEGIN TRY
        SELECT @n = COUNT(*) FROM dbo.KnowledgeChunks;
        SET @canRead = 1;
    END TRY
    BEGIN CATCH SET @roleErr += CONCAT(N'read: ', ERROR_MESSAGE(), N' '); END CATCH;
    BEGIN TRY
        DELETE FROM dbo.KnowledgeChunks WHERE 1 = 0;
    END TRY
    BEGIN CATCH SET @deleteDenied = IIF(ERROR_NUMBER() = 229, 1, 0); END CATCH;
    BEGIN TRY
        SELECT @n = COUNT(*) FROM dbo.OllamaLogs;
    END TRY
    BEGIN CATCH SET @logsDenied = IIF(ERROR_NUMBER() = 229, 1, 0); END CATCH;
REVERT;
INSERT @log VALUES (N'T7 acmekb_api role: can read and search, cannot delete chunks or read logs',
    IIF(@canSearch = 1 AND @canRead = 1 AND @deleteDenied = 1 AND @logsDenied = 1, 1, 0),
    CONCAT(N'search=', @canSearch, N' read=', @canRead, N' deleteDenied=', @deleteDenied, N' logsDenied=', @logsDenied, N' ', @roleErr));

ROLLBACK;

/* ---------- T8: search on the seed data (read-only) ---------- */
SET @args = N'{"QueryText":"Customers stopped receiving notification emails after the upgrade","TopN":3,"MinSimilarity":0}';
EXEC dbo.sp_SearchKnowledgeBase @ArgsJson = @args, @Result = @r OUTPUT;
INSERT @log SELECT N'T8 Search: TopN=3 respected, full-text contributes, ACME-1001 in results',
    IIF(ISJSON(@r) = 1 AND cnt BETWEEN 1 AND 3 AND fts > 0 AND hit > 0, 1, 0),
    CONCAT(N'rows=', cnt, N' withFTS=', fts, N' | ', rows)
FROM (SELECT COUNT(*) cnt, COUNT(FTSRank) fts,
             SUM(IIF(Title = N'Notification emails stopped after upgrade to 4.2', 1, 0)) hit,
             STRING_AGG(CONCAT(N'[', ChunkID, N' ', Title, N' v=', VectorSimilarity, N' vr=', VectorRank, N' fr=', FTSRank, N']'), N' ') rows
      FROM OPENJSON(IIF(ISJSON(@r) = 1, @r, N'[]')) WITH (ChunkID BIGINT, Title NVARCHAR(500), VectorSimilarity FLOAT, VectorRank INT, FTSRank INT)) q;

/* ---------- T9: filters by AppName and DocType ---------- */
SET @args = N'{"QueryText":"single sign-on login problem","AppName":"Acme Mobile","DocType":"HelpdeskTicket","TopN":5,"MinSimilarity":0}';
EXEC dbo.sp_SearchKnowledgeBase @ArgsJson = @args, @Result = @r OUTPUT;
INSERT @log SELECT N'T9 Search filters AppName + DocType',
    IIF(COUNT(*) > 0 AND SUM(IIF(AppName = N'Acme Mobile' AND DocType = N'HelpdeskTicket', 0, 1)) = 0, 1, 0),
    CONCAT(N'rows=', COUNT(*), N' | ', STRING_AGG(CONCAT(AppName, N'/', DocType, N'/', Title), N'; '))
FROM OPENJSON(IIF(ISJSON(@r) = 1, @r, N'[]')) WITH (AppName NVARCHAR(100), DocType NVARCHAR(50), Title NVARCHAR(255));

/* ---------- T10: default TopN = 5, default MinSimilarity = 0.5 ---------- */
SET @args = N'{"QueryText":"error"}';
EXEC dbo.sp_SearchKnowledgeBase @ArgsJson = @args, @Result = @r OUTPUT;
INSERT @log SELECT N'T10 Search defaults: at most 5 rows, vector hits >= 0.5',
    IIF(COUNT(*) BETWEEN 1 AND 5 AND ISNULL(MIN(VectorSimilarity), 1) >= 0.5, 1, 0),
    CONCAT(N'rows=', COUNT(*), N' minVector=', MIN(VectorSimilarity))
FROM OPENJSON(IIF(ISJSON(@r) = 1, @r, N'[]')) WITH (VectorSimilarity FLOAT);

/* ---------- T11: bad input ---------- */
EXEC dbo.sp_SearchKnowledgeBase @ArgsJson = N'not json', @Result = @r OUTPUT;
INSERT @log VALUES (N'T11 Search: invalid JSON handled', IIF(@r LIKE N'Error:%', 1, 0), @r);

/* ---------- T12: removed engine parameters are rejected ---------- */
BEGIN TRY
    EXEC dbo.sp_ExecuteOllamaSkillEngine @UserPrompt = N'x', @OllamaUrl = N'https://example.com';
    INSERT @log VALUES (N'T12 Engine rejects @OllamaUrl', 0, N'call accepted');
END TRY
BEGIN CATCH
    INSERT @log VALUES (N'T12 Engine rejects @OllamaUrl', 1, ERROR_MESSAGE());
END CATCH;

/* ---------- report ---------- */
SELECT CAST(CONCAT(IIF(ok = 1, N'PASS ', N'FAIL '), test, CHAR(10), N'     ', detail) AS NVARCHAR(MAX)) AS Result
FROM @log ORDER BY id;

DECLARE @failed INT = (SELECT COUNT(*) FROM @log WHERE ok = 0), @total INT = (SELECT COUNT(*) FROM @log);
PRINT CONCAT(@total - @failed, N' of ', @total, N' tests passed.');
IF @failed > 0
    THROW 50200, N'AcmeKB tests failed.', 1;
GO
