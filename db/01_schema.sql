/* =====================================================================
   AcmeKB: schema
   RAG knowledge base inside SQL Server 2025:
     - KnowledgeChunks + KnowledgeEmbeddings (VECTOR(1024)) + full-text index
     - ChatSessions / ChatMessages / OllamaLogs for the agent engine
     - SkillRegistry / SkillTools: tools the model can load on demand
   Requirements:
     - SQL Server 2025 (VECTOR type, AI_GENERATE_EMBEDDINGS, EXTERNAL MODEL)
     - Full-Text Search feature installed
     - 'external rest endpoint enabled' = 1 (sp_configure, server level)
     - Ollama reachable over HTTPS (SQL Server only calls HTTPS endpoints);
       see README.md for a local reverse proxy
   Run with sqlcmd (uses :on error exit). Safe to re-run: objects are
   created only when missing.
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
GO

IF DB_ID(N'AcmeKB') IS NULL
    CREATE DATABASE AcmeKB;
GO

USE AcmeKB;
GO

IF (SELECT CAST(value_in_use AS INT) FROM sys.configurations WHERE name = N'external rest endpoint enabled') <> 1
    RAISERROR(N'Warning: ''external rest endpoint enabled'' is 0. Embeddings and the agent engine will fail until it is enabled.', 10, 1) WITH NOWAIT;
GO

/* ---------------------------------------------------------------------
   Knowledge base
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.KnowledgeChunks', N'U') IS NULL
CREATE TABLE dbo.KnowledgeChunks
(
    ChunkID       BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_KnowledgeChunks PRIMARY KEY,
    AppName       NVARCHAR(100) NOT NULL,
    ModuleName    NVARCHAR(100) NOT NULL,
    DocType       NVARCHAR(50)  NOT NULL,            -- HelpdeskTicket, ReleaseNote, TechnicalDoc, ...
    Breadcrumbs   NVARCHAR(500) NULL,                -- "Document > Chapter > Section"
    AppVersion    NVARCHAR(50)  NULL,
    EventDate     DATETIME2     NULL,
    CreatedAt     DATETIME2     NOT NULL CONSTRAINT DF_KnowledgeChunks_CreatedAt DEFAULT SYSDATETIME(),
    DocumentID    NVARCHAR(100) NULL,                -- ticket id / document id; re-ingest replaces by it
    ChunkIndex    INT           NOT NULL CONSTRAINT DF_KnowledgeChunks_ChunkIndex DEFAULT 0,
    Title         NVARCHAR(255) NULL,
    MainContent   NVARCHAR(MAX) NOT NULL,
    SearchContext NVARCHAR(MAX) NULL,                -- summary / likely user questions, embedded separately
    MetadataJson  NVARCHAR(MAX) NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_KnowledgeChunks_Search' AND object_id = OBJECT_ID(N'dbo.KnowledgeChunks'))
    CREATE INDEX IX_KnowledgeChunks_Search ON dbo.KnowledgeChunks (AppName, ModuleName, DocType);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_KnowledgeChunks_Document' AND object_id = OBJECT_ID(N'dbo.KnowledgeChunks'))
    CREATE INDEX IX_KnowledgeChunks_Document ON dbo.KnowledgeChunks (DocumentID, ChunkIndex);
GO

-- One chunk has up to two vectors: VectorType = 'MainContent' and 'SearchContext'
IF OBJECT_ID(N'dbo.KnowledgeEmbeddings', N'U') IS NULL
CREATE TABLE dbo.KnowledgeEmbeddings
(
    EmbeddingID BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_KnowledgeEmbeddings PRIMARY KEY,
    ChunkID     BIGINT       NOT NULL
        CONSTRAINT FK_KnowledgeEmbeddings_Chunk REFERENCES dbo.KnowledgeChunks (ChunkID) ON DELETE CASCADE,
    VectorType  NVARCHAR(50) NOT NULL,
    Embedding   VECTOR(1024) NOT NULL,               -- qwen3-embedding:0.6b returns 1024 dimensions
    CreatedAt   DATETIME2    NOT NULL CONSTRAINT DF_KnowledgeEmbeddings_CreatedAt DEFAULT SYSDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_KnowledgeEmbeddings_Chunk' AND object_id = OBJECT_ID(N'dbo.KnowledgeEmbeddings'))
    CREATE INDEX IX_KnowledgeEmbeddings_Chunk ON dbo.KnowledgeEmbeddings (ChunkID, VectorType);
GO

/* ---------------------------------------------------------------------
   Chat history and engine logs
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.ChatSessions', N'U') IS NULL
CREATE TABLE dbo.ChatSessions
(
    SessionID UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ChatSessions PRIMARY KEY
        CONSTRAINT DF_ChatSessions_SessionID DEFAULT NEWID(),
    Title     NVARCHAR(255) NOT NULL CONSTRAINT DF_ChatSessions_Title DEFAULT N'New Conversation',
    CreatedAt DATETIME2     NOT NULL CONSTRAINT DF_ChatSessions_CreatedAt DEFAULT SYSDATETIME(),
    UpdatedAt DATETIME2     NOT NULL CONSTRAINT DF_ChatSessions_UpdatedAt DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID(N'dbo.ChatMessages', N'U') IS NULL
CREATE TABLE dbo.ChatMessages
(
    MessageID     BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ChatMessages PRIMARY KEY,
    SessionID     UNIQUEIDENTIFIER NOT NULL
        CONSTRAINT FK_ChatMessages_Session REFERENCES dbo.ChatSessions (SessionID) ON DELETE CASCADE,
    Role          NVARCHAR(50)  NOT NULL,            -- user / assistant / tool
    Content       NVARCHAR(MAX) NULL,
    ToolCallsJson NVARCHAR(MAX) NULL,                -- tool_calls of an assistant step
    ToolCallID    NVARCHAR(100) NULL,
    CreatedAt     DATETIME2     NOT NULL CONSTRAINT DF_ChatMessages_CreatedAt DEFAULT SYSDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ChatMessages_SessionID' AND object_id = OBJECT_ID(N'dbo.ChatMessages'))
    CREATE INDEX IX_ChatMessages_SessionID ON dbo.ChatMessages (SessionID);
GO

-- No FK to ChatSessions on purpose: logs outlive deleted conversations
IF OBJECT_ID(N'dbo.OllamaLogs', N'U') IS NULL
CREATE TABLE dbo.OllamaLogs
(
    LogID           BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_OllamaLogs PRIMARY KEY,
    SessionID       UNIQUEIDENTIFIER NOT NULL,
    StepNumber      INT           NOT NULL,
    ModelName       NVARCHAR(100) NOT NULL,
    RequestPayload  NVARCHAR(MAX) NULL,
    ResponsePayload NVARCHAR(MAX) NULL,
    ExecutionTimeMs INT           NULL,
    HasError        BIT           NOT NULL CONSTRAINT DF_OllamaLogs_HasError DEFAULT 0,
    ErrorMessage    NVARCHAR(MAX) NULL,
    CreatedAt       DATETIME2     NOT NULL CONSTRAINT DF_OllamaLogs_CreatedAt DEFAULT SYSDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_OllamaLogs_SessionID' AND object_id = OBJECT_ID(N'dbo.OllamaLogs'))
    CREATE INDEX IX_OllamaLogs_SessionID ON dbo.OllamaLogs (SessionID);
GO

/* ---------------------------------------------------------------------
   Skills: the model starts with sp_LoadSkill only and loads tools on demand
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.SkillRegistry', N'U') IS NULL
CREATE TABLE dbo.SkillRegistry
(
    SkillName   NVARCHAR(100) NOT NULL CONSTRAINT PK_SkillRegistry PRIMARY KEY,
    Description NVARCHAR(MAX) NOT NULL,
    IsActive    BIT           NOT NULL CONSTRAINT DF_SkillRegistry_IsActive DEFAULT 1,
    CreatedAt   DATETIME2     NOT NULL CONSTRAINT DF_SkillRegistry_CreatedAt DEFAULT SYSDATETIME()
);
GO

-- FunctionName = name of a dbo procedure with the (@ArgsJson, @Result OUTPUT) signature
IF OBJECT_ID(N'dbo.SkillTools', N'U') IS NULL
CREATE TABLE dbo.SkillTools
(
    ToolID               INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_SkillTools PRIMARY KEY,
    SkillName            NVARCHAR(100) NOT NULL
        CONSTRAINT FK_SkillTools_Skill REFERENCES dbo.SkillRegistry (SkillName) ON DELETE CASCADE,
    FunctionName         NVARCHAR(128) NOT NULL CONSTRAINT UQ_SkillTools_FunctionName UNIQUE,
    FunctionDescription  NVARCHAR(MAX) NOT NULL,
    ParametersSchemaJson NVARCHAR(MAX) NOT NULL
        CONSTRAINT CK_SkillTools_ParametersSchemaJson CHECK (ISJSON(ParametersSchemaJson) = 1),
    IsActive             BIT           NOT NULL CONSTRAINT DF_SkillTools_IsActive DEFAULT 1
);
GO

/* ---------------------------------------------------------------------
   Full-text index (English word breaker, used by FREETEXTTABLE)
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = N'ftCatalog_Knowledge')
    CREATE FULLTEXT CATALOG ftCatalog_Knowledge;
GO

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID(N'dbo.KnowledgeChunks'))
    CREATE FULLTEXT INDEX ON dbo.KnowledgeChunks
    (
        Title         LANGUAGE 1033,
        MainContent   LANGUAGE 1033,
        SearchContext LANGUAGE 1033
    )
    KEY INDEX PK_KnowledgeChunks
    ON ftCatalog_Knowledge
    WITH CHANGE_TRACKING AUTO;
GO

/* ---------------------------------------------------------------------
   Embedding model (Ollama). SQL Server calls it from
   AI_GENERATE_EMBEDDINGS(... USE MODEL MyOllamaEmbeddingModel).
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'MyOllamaEmbeddingModel')
    CREATE EXTERNAL MODEL MyOllamaEmbeddingModel
    WITH (
        LOCATION = N'https://localhost/api/embed',
        API_FORMAT = N'Ollama',
        MODEL_TYPE = EMBEDDINGS,
        MODEL = N'qwen3-embedding:0.6b',
        PARAMETERS = N'{"sql_rest_options":{"retry_count":3}}'
    );
GO

/* ---------------------------------------------------------------------
   Least-privilege database role for the API (Data API builder).
   Add a user to it when DAB connects with its own login:
     CREATE USER [acmekb_api] FOR LOGIN [acmekb_api];
     ALTER ROLE acmekb_api ADD MEMBER [acmekb_api];
   Grants on procedures are in 02_procs.sql (they must exist first).
   --------------------------------------------------------------------- */
IF DATABASE_PRINCIPAL_ID(N'acmekb_api') IS NULL
    CREATE ROLE acmekb_api;
GO

-- Reads for the UI; writes only where the editor role of the API needs them
GRANT SELECT ON dbo.KnowledgeChunks TO acmekb_api;
GRANT INSERT, UPDATE ON dbo.KnowledgeChunks TO acmekb_api;
GRANT SELECT ON dbo.ChatSessions TO acmekb_api;
GRANT DELETE ON dbo.ChatSessions TO acmekb_api;
GRANT SELECT ON dbo.ChatMessages TO acmekb_api;
-- The engine calls tools through sp_executesql, which breaks ownership chaining:
-- the caller needs the REST endpoint and model permissions itself.
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO acmekb_api;
GRANT EXECUTE ON EXTERNAL MODEL::MyOllamaEmbeddingModel TO acmekb_api;
-- Explicitly no DELETE on KnowledgeChunks, no access to OllamaLogs, Skill* or embeddings
GO

PRINT N'AcmeKB schema ready.';
GO
