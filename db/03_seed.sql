/* =====================================================================
   AcmeKB: seed data
   Everything here is fictional: "Acme Helpdesk" is a made-up help desk
   product (web app "Acme Helpdesk" + companion app "Acme Mobile").
   Data is loaded through the same procedures the agent uses, so every
   chunk gets its embeddings from Ollama. Needs the embedding model online.
   Re-running the script replaces the Acme data and the skill registry.
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

USE AcmeKB;
GO

/* ---------------------------------------------------------------------
   1. Skill registry
   --------------------------------------------------------------------- */
DELETE FROM dbo.SkillRegistry;   -- SkillTools cascade

INSERT INTO dbo.SkillRegistry (SkillName, Description) VALUES
(N'KnowledgeSearch',         N'Hybrid (vector + full-text) search across release notes, support tickets and technical documentation.'),
(N'HelpdeskManagement',      N'Records resolved support tickets (problem + solution) in the knowledge base.'),
(N'ReleaseManagement',       N'Records software release notes, version change logs and feature announcements.'),
(N'DocumentationManagement', N'Ingests large technical documents split into chunks with breadcrumbs.');

INSERT INTO dbo.SkillTools (SkillName, FunctionName, FunctionDescription, ParametersSchemaJson) VALUES
(N'KnowledgeSearch', N'sp_SearchKnowledgeBase',
 N'Hybrid search of the knowledge base: vector similarity (SQL Server 2025 embeddings) fused with full-text ranking (RRF).',
 N'{
    "type": "object",
    "properties": {
        "QueryText": { "type": "string", "description": "Natural language user query or question to search for." },
        "AppName": { "type": "string", "description": "Optional filter by application name (Acme Helpdesk, Acme Mobile)." },
        "DocType": { "type": "string", "description": "Optional filter by document type (ReleaseNote, HelpdeskTicket, TechnicalDoc)." },
        "TopN": { "type": "integer", "description": "Maximum number of relevant chunks to return (default is 5)." },
        "MinSimilarity": { "type": "number", "description": "Minimum vector similarity between 0.0 and 1.0 (default is 0.5)." }
    },
    "required": ["QueryText"]
}'),
(N'HelpdeskManagement', N'sp_AddHelpdeskTicket',
 N'Stores a resolved support ticket with its problem description and solution in the knowledge base.',
 N'{
    "type": "object",
    "properties": {
        "AppName": { "type": "string", "description": "Target application name." },
        "ModuleName": { "type": "string", "description": "Module where the issue occurred." },
        "TicketID": { "type": "string", "description": "Ticket identifier, e.g. ACME-1042." },
        "IssueTitle": { "type": "string", "description": "Short summary of the reported issue." },
        "ProblemDescription": { "type": "string", "description": "Detailed description of the problem or error message." },
        "SolutionDescription": { "type": "string", "description": "Step-by-step resolution or fix." },
        "HypotheticalQuestions": { "type": "string", "description": "Alternative phrasings of the symptom as users would ask." }
    },
    "required": ["AppName", "ModuleName", "ProblemDescription", "SolutionDescription"]
}'),
(N'ReleaseManagement', N'sp_AddReleaseNote',
 N'Records a new software version release note in the knowledge base.',
 N'{
    "type": "object",
    "properties": {
        "AppName": { "type": "string", "description": "Target application name." },
        "ModuleName": { "type": "string", "description": "Subsystem or module name." },
        "AppVersion": { "type": "string", "description": "Release version string, e.g. 4.2.0." },
        "ReleaseDate": { "type": "string", "description": "Date of release (YYYY-MM-DD)." },
        "Title": { "type": "string", "description": "Release title or short headline." },
        "ReleaseNotesContent": { "type": "string", "description": "Full release note content including new features and bug fixes." },
        "KeyHighlights": { "type": "string", "description": "Short summary of major changes for search." }
    },
    "required": ["AppName", "ModuleName", "AppVersion", "ReleaseNotesContent"]
}'),
(N'DocumentationManagement', N'sp_AddTechnicalDoc',
 N'Ingests a technical document split into chunks with breadcrumbs; re-ingesting the same DocID replaces it.',
 N'{
    "type": "object",
    "properties": {
        "DocID": { "type": "string", "description": "Unique document identifier, e.g. DOC-API-001." },
        "AppName": { "type": "string", "description": "Target application name." },
        "ModuleName": { "type": "string", "description": "Optional module name (e.g. Integrations, Email Gateway)." },
        "DocType": { "type": "string", "description": "Document category (TechnicalDoc, Architecture, UserGuide)." },
        "AppVersion": { "type": "string", "description": "Software version." },
        "DocumentTitle": { "type": "string", "description": "Root title of the document." },
        "Chunks": {
            "type": "array",
            "description": "Document sections divided into chunks.",
            "items": {
                "type": "object",
                "properties": {
                    "Title": { "type": "string", "description": "Section title." },
                    "MainContent": { "type": "string", "description": "Text of the chunk." },
                    "SearchContext": { "type": "string", "description": "Optional summary or keywords for retrieval." },
                    "Breadcrumbs": { "type": "string", "description": "Path inside the document, e.g. Chapter 1 > Section 1.2." }
                },
                "required": ["MainContent"]
            }
        }
    },
    "required": ["DocID", "AppName", "DocumentTitle", "Chunks"]
}');
GO

/* ---------------------------------------------------------------------
   2. Reset demo knowledge (embeddings cascade)
   --------------------------------------------------------------------- */
DELETE FROM dbo.KnowledgeChunks WHERE AppName IN (N'Acme Helpdesk', N'Acme Mobile');
GO

/* ---------------------------------------------------------------------
   3. Helpdesk tickets
   --------------------------------------------------------------------- */
DECLARE @Tickets TABLE (
    Seq INT IDENTITY, AppName NVARCHAR(100), ModuleName NVARCHAR(100), TicketID NVARCHAR(100), IssueTitle NVARCHAR(255),
    ProblemDescription NVARCHAR(MAX), SolutionDescription NVARCHAR(MAX), HypotheticalQuestions NVARCHAR(MAX));

INSERT INTO @Tickets (AppName, ModuleName, TicketID, IssueTitle, ProblemDescription, SolutionDescription, HypotheticalQuestions) VALUES
(N'Acme Helpdesk', N'Email Gateway', N'ACME-1001', N'Notification emails stopped after upgrade to 4.2',
 N'After upgrading Acme Helpdesk from 4.1.3 to 4.2.0, agents and customers no longer receive notification emails. The outbound queue in Admin > Email > Queue grows and the gateway log shows "535 5.7.3 Authentication unsuccessful".',
 N'Version 4.2.0 switched the SMTP connector to OAuth 2.0 by default. Either register the app in the mail provider and fill Admin > Email > Outbound > OAuth client settings, or set Authentication = Basic (legacy) for the connector. Then click "Retry queued messages". The queue drains within a few minutes.',
 N'Why are emails not sent after the update? Customers do not get ticket notifications. SMTP 535 error in the email gateway log.'),
(N'Acme Helpdesk', N'Email Gateway', N'ACME-1002', N'Replies from customers create new tickets instead of threading',
 N'Customer replies to notification emails open a new ticket every time instead of being added as a comment to the original ticket.',
 N'The mail client of the customer strips the [#ACME-xxxx] token from the subject. Enable Admin > Email > Inbound > "Match by Message-ID / In-Reply-To headers" (available since 4.0). Existing duplicates can be merged with Ticket > Actions > Merge.',
 N'Customer reply creates a duplicate ticket. Email threading does not work. How to merge tickets created from replies?'),
(N'Acme Helpdesk', N'Email Gateway', N'ACME-1003', N'Inbound mailbox polling stuck',
 N'New emails to support@ are not converted to tickets. The mailbox poller status shows "Running" but the last poll time is several hours old.',
 N'The IMAP poller holds a lock row in the jobs table after an unclean service restart. Go to Admin > System > Background jobs, select "Inbound mail poller" and click "Release lock", or restart the Acme Worker service. Upgrade to 4.2.1, which expires stale locks after 10 minutes.',
 N'Emails are not turning into tickets. Mailbox poller is stuck. Last poll time is old.'),
(N'Acme Helpdesk', N'SLA Engine', N'ACME-1004', N'SLA timers keep running on weekends',
 N'Tickets breach their first response SLA over the weekend although the support team works Monday to Friday only.',
 N'The SLA policy was linked to the "24x7" calendar. Open Admin > SLA > Policies, edit the policy and select the "Business hours (Mon-Fri)" calendar. Timers of open tickets are recalculated on the next SLA engine run (every 5 minutes).',
 N'SLA breached on Saturday. Business hours are ignored. How to pause SLA outside working hours?'),
(N'Acme Helpdesk', N'SLA Engine', N'ACME-1005', N'Wrong SLA due dates after daylight saving time change',
 N'After the switch to summer time all SLA due dates are shifted by one hour for agents in the Europe/Berlin time zone.',
 N'Fixed in 4.1.2: due dates are now stored in UTC and converted per agent time zone. On older versions run Admin > SLA > Maintenance > "Recalculate due dates" after each DST change.',
 N'SLA due date is off by one hour. Daylight saving time problem. Time zone shift in SLA.'),
(N'Acme Helpdesk', N'SLA Engine', N'ACME-1006', N'Pausing SLA while waiting for customer',
 N'Tickets in status "Waiting for customer" still count towards the resolution SLA, which makes the team look slow in reports.',
 N'Edit the SLA policy and add "Waiting for customer" to "Pause statuses". The pause applies to new status changes; for historical tickets use Reports > SLA > "Recalculate history".',
 N'How to stop the SLA clock when waiting for customer reply? SLA pause statuses.'),
(N'Acme Helpdesk', N'Ticketing', N'ACME-1007', N'Bulk close fails with timeout',
 N'Selecting more than 500 tickets in a view and choosing "Close" ends with "Request timed out" and only part of the tickets are closed.',
 N'Bulk actions above 200 items run as a background job since 4.2.0. On 4.1.x split the selection into batches of 200 or use the REST API endpoint POST /api/v2/tickets/bulk with "async": true.',
 N'Cannot close many tickets at once. Bulk update timeout. Mass close tickets.'),
(N'Acme Helpdesk', N'Ticketing', N'ACME-1008', N'Attachments larger than 10 MB are rejected',
 N'Agents get "File too large" when attaching log files of 15-30 MB to a ticket.',
 N'The default limit is 10 MB. Change Admin > Ticketing > Attachments > "Maximum file size" (up to 100 MB). If Acme Helpdesk runs behind a reverse proxy, raise the request body limit there as well (for example client_max_body_size in nginx).',
 N'How to upload big attachments? File too large error. Increase attachment size limit.'),
(N'Acme Helpdesk', N'Ticketing', N'ACME-1009', N'Custom field values disappear after ticket merge',
 N'When two tickets are merged, values of custom fields of the secondary ticket are lost.',
 N'By design the primary ticket keeps its own values. Since 4.2.0 the merge dialog shows a "Field conflicts" step where the agent picks the value per field. On older versions copy the values manually before merging.',
 N'Merge tickets loses custom fields. Which values are kept when merging?'),
(N'Acme Helpdesk', N'Ticketing', N'ACME-1010', N'Auto-assignment sends all tickets to one agent',
 N'Round-robin assignment for the L1 queue assigns every new ticket to the same agent.',
 N'Round-robin skips agents whose status is not "Available". Only one agent had the status set; the others were "Offline" because the desktop app was closed. Ask agents to set their status, or switch the queue to "Load balanced (ignore status)".',
 N'Round robin does not work. Every ticket goes to the same person. Auto assignment problem.'),
(N'Acme Helpdesk', N'Knowledge Portal', N'ACME-1011', N'Customer portal search returns no articles',
 N'Searching the public knowledge portal returns "No results" for words that clearly appear in published articles.',
 N'The portal search index was not rebuilt after the import of 300 articles. Run Admin > Knowledge Portal > Search > "Rebuild index". Indexing takes about one minute per 1,000 articles. Articles must also be in status Published and visible to "Customers".',
 N'Portal search finds nothing. Knowledge articles are not searchable. Rebuild search index.'),
(N'Acme Helpdesk', N'Knowledge Portal', N'ACME-1012', N'Images missing in exported PDF articles',
 N'Exporting a knowledge article to PDF produces a document without images.',
 N'Images were stored as external links to a host that requires authentication. Re-upload the images into the article so they are stored in Acme Helpdesk, then export again.',
 N'PDF export has no pictures. Article images missing in PDF.'),
(N'Acme Helpdesk', N'Reporting', N'ACME-1013', N'Agent performance report is empty',
 N'The "Agent performance" report shows no data for the previous month.',
 N'Reports read from the nightly aggregate. The aggregation job was disabled after a restore of the database. Enable Admin > System > Background jobs > "Nightly report aggregation" and run it once with "Backfill from" set to the first day of the missing month.',
 N'Report shows no data. Agent statistics missing. Nightly aggregation not running.'),
(N'Acme Helpdesk', N'Reporting', N'ACME-1014', N'CSV export breaks non-Latin characters',
 N'Ticket exports opened in a spreadsheet show garbled characters for names in Greek and Polish.',
 N'The CSV file is UTF-8 without BOM. Use Reports > Export > "UTF-8 with BOM (Excel)" format, or import the CSV via Data > From Text and choose UTF-8.',
 N'Export shows strange characters. CSV encoding problem in Excel.'),
(N'Acme Helpdesk', N'Integrations', N'ACME-1015', N'Webhook calls fail with 401 after rotating the secret',
 N'Outgoing webhooks to the internal CRM fail with HTTP 401 since the webhook secret was rotated.',
 N'The receiver validates the X-Acme-Signature header with the old secret. Update the secret on the receiving side. Webhooks have a 24-hour grace period where both secrets are sent (X-Acme-Signature and X-Acme-Signature-Previous) if "Rotate with grace period" is used instead of "Regenerate".',
 N'Webhook unauthorized 401. Rotate webhook secret without downtime. Signature validation fails.'),
(N'Acme Helpdesk', N'Integrations', N'ACME-1016', N'REST API returns 429 Too Many Requests',
 N'A nightly sync script that reads all tickets through the REST API stops with HTTP 429 after a few minutes.',
 N'The API allows 600 requests per minute per token. Use the cursor-based endpoint GET /api/v2/tickets?updated_since=...&page_size=500 instead of fetching tickets one by one, and honour the Retry-After header.',
 N'API rate limit exceeded. 429 error from Acme API. How many requests per minute are allowed?'),
(N'Acme Helpdesk', N'Integrations', N'ACME-1017', N'Chat widget does not load on customer website',
 N'The embedded chat widget does not appear on the customer website; the browser console shows a Content Security Policy error.',
 N'Add the Acme widget host to the script-src and connect-src directives of the website CSP, and to frame-src when the pre-chat form is enabled. The exact list is in Admin > Channels > Chat > Install.',
 N'Chat widget not visible. CSP blocks Acme widget. Live chat script refused to load.'),
(N'Acme Helpdesk', N'Authentication', N'ACME-1018', N'SSO login loops back to the sign-in page',
 N'After enabling SAML single sign-on, agents are redirected to the identity provider and back to the Acme sign-in page endlessly.',
 N'The Assertion Consumer Service URL in the identity provider pointed to http:// while Acme Helpdesk runs on https://. Fix the ACS URL, and make sure the NameID format is emailAddress and matches the agent email in Acme.',
 N'SAML redirect loop. Cannot log in with SSO. Single sign-on keeps redirecting.'),
(N'Acme Helpdesk', N'Authentication', N'ACME-1019', N'Agents logged out every 15 minutes',
 N'Agents complain that they are signed out several times per hour and lose unsaved replies.',
 N'Session timeout was set to 15 minutes of inactivity under Admin > Security > Sessions. Set it to 8 hours or enable "Keep me signed in". Since 4.2.0 reply drafts are autosaved every 10 seconds.',
 N'Session expires too fast. Why am I logged out? Lost my reply draft.'),
(N'Acme Helpdesk', N'Authentication', N'ACME-1020', N'Two-factor codes rejected',
 N'An agent enters the code from the authenticator app but gets "Invalid verification code".',
 N'The clock of the phone was 3 minutes off. Enable automatic time on the device. An admin can reset 2FA for the agent in Admin > Agents > Security > "Reset two-factor".',
 N'2FA code invalid. Authenticator app code not accepted. Reset two-factor authentication.'),
(N'Acme Mobile', N'Push Notifications', N'ACME-1021', N'No push notifications on Android',
 N'Agents using Acme Mobile on Android do not get push notifications for new assigned tickets; iOS works.',
 N'Battery optimisation stops the app in the background. On the device open Settings > Apps > Acme Mobile > Battery and choose "Unrestricted". Version 2.3.0 shows a hint during onboarding.',
 N'Android push not working. Mobile app no notifications. Battery optimisation kills the app.'),
(N'Acme Mobile', N'Offline Mode', N'ACME-1022', N'Offline replies are sent twice',
 N'Replies written in Acme Mobile while offline are posted twice once the connection returns.',
 N'Fixed in Acme Mobile 2.2.1: the offline queue now uses an idempotency key per reply. Update the app; duplicates can be deleted by an admin from the ticket history.',
 N'Duplicate replies from mobile. Offline sync sends message twice.'),
(N'Acme Mobile', N'Authentication', N'ACME-1023', N'Mobile app cannot sign in with SSO',
 N'Acme Mobile shows "Unsupported identity provider response" after the company enabled SAML SSO.',
 N'Acme Mobile uses OpenID Connect, not SAML. Enable "OIDC for mobile" in Admin > Security > Single sign-on and add the redirect URI acme-mobile://auth/callback in the identity provider.',
 N'Mobile login with SSO fails. SAML on the mobile app. Redirect URI for Acme Mobile.'),
(N'Acme Helpdesk', N'Ticketing', N'ACME-1024', N'Ticket view sorting resets after reload',
 N'Agents sort a ticket view by priority, but after a page reload the view is sorted by creation date again.',
 N'Sorting is saved per view only for the view owner. Shared views use the sorting configured by the admin in Admin > Views. Agents can clone the view ("Save as personal view") to keep their own sorting.',
 N'Sort order is not saved. View sorting resets. Personal view settings.'),
(N'Acme Helpdesk', N'Email Gateway', N'ACME-1025', N'Notification emails land in spam',
 N'Customers find ticket notifications in their spam folder.',
 N'The sending domain had no SPF and DKIM records for the Acme mail relay. Publish the SPF include and the DKIM CNAME records shown in Admin > Email > Domains, wait for verification, and add a DMARC policy.',
 N'Emails go to junk. SPF DKIM setup for Acme notifications. Deliverability problem.'),
(N'Acme Helpdesk', N'SLA Engine', N'ACME-1026', N'Escalation emails sent for closed tickets',
 N'Managers receive SLA escalation emails for tickets that were closed an hour earlier.',
 N'Escalation jobs were queued before the ticket was closed and the queue was delayed. Fixed in 4.2.1: the escalation job re-checks the ticket status before sending. Workaround: increase the SLA engine run frequency to 1 minute.',
 N'Escalation for closed ticket. Wrong SLA escalation email.');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Tickets), @args NVARCHAR(MAX), @r NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SET @args = (SELECT AppName, ModuleName, TicketID, IssueTitle, ProblemDescription, SolutionDescription, HypotheticalQuestions
                 FROM @Tickets WHERE Seq = @i FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_AddHelpdeskTicket @ArgsJson = @args, @Result = @r OUTPUT;
    IF @r NOT LIKE N'Helpdesk ticket successfully recorded%'
        BEGIN DECLARE @m NVARCHAR(2048) = LEFT(@r, 2048); THROW 50100, @m, 1; END;
    SET @i += 1;
END;
PRINT CONCAT(N'Tickets: ', @n);
GO

/* ---------------------------------------------------------------------
   4. Release notes
   --------------------------------------------------------------------- */
DECLARE @Releases TABLE (
    Seq INT IDENTITY, AppName NVARCHAR(100), ModuleName NVARCHAR(100), AppVersion NVARCHAR(50), ReleaseDate NVARCHAR(10),
    Title NVARCHAR(255), ReleaseNotesContent NVARCHAR(MAX), KeyHighlights NVARCHAR(MAX));

INSERT INTO @Releases (AppName, ModuleName, AppVersion, ReleaseDate, Title, ReleaseNotesContent, KeyHighlights) VALUES
(N'Acme Helpdesk', N'Platform', N'4.0.0', N'2026-03-02', N'Acme Helpdesk 4.0: new agent workspace',
 N'New features: redesigned agent workspace with split view; inbound email threading by Message-ID / In-Reply-To headers; custom ticket statuses; REST API v2 with cursor-based pagination. Breaking changes: REST API v1 is deprecated and will be removed in 5.0. Fixed: attachments with non-ASCII file names could not be downloaded.',
 N'Agent workspace redesign, email threading by headers, custom statuses, REST API v2, API v1 deprecated'),
(N'Acme Helpdesk', N'SLA Engine', N'4.1.0', N'2026-05-18', N'Acme Helpdesk 4.1: SLA calendars',
 N'New features: multiple business-hour calendars per SLA policy; holiday lists; pause statuses for SLA timers; SLA history recalculation report. Improvements: SLA engine runs every 5 minutes instead of 15. Fixed: escalation rules ignored ticket priority changes.',
 N'Business-hour calendars, holidays, SLA pause statuses, faster SLA engine'),
(N'Acme Helpdesk', N'SLA Engine', N'4.1.2', N'2026-06-30', N'Acme Helpdesk 4.1.2 maintenance release',
 N'Fixed: SLA due dates shifted by one hour after daylight saving time changes (dates are now stored in UTC); report export failed for date ranges longer than one year; knowledge portal search ignored article tags.',
 N'DST fix for SLA due dates, long report exports, portal tag search'),
(N'Acme Helpdesk', N'Platform', N'4.2.0', N'2026-09-14', N'Acme Helpdesk 4.2: OAuth email and background bulk actions',
 N'New features: OAuth 2.0 for outbound SMTP and inbound IMAP connectors (now the default for new and upgraded connectors); bulk actions above 200 tickets run as background jobs; field conflict resolution when merging tickets; reply drafts are autosaved every 10 seconds. Upgrade notes: after upgrading, check Admin > Email > Outbound - connectors that used a password switch to OAuth and need client settings, or must be set back to Basic (legacy) authentication.',
 N'OAuth SMTP/IMAP by default (check email after upgrade), background bulk actions, merge conflicts dialog, draft autosave'),
(N'Acme Helpdesk', N'Platform', N'4.2.1', N'2026-10-20', N'Acme Helpdesk 4.2.1 maintenance release',
 N'Fixed: stale lock of the inbound mail poller after an unclean service restart (locks now expire after 10 minutes); SLA escalation emails sent for tickets closed in the meantime; webhook retries did not respect the exponential back-off. Security: session cookies now use SameSite=Lax by default.',
 N'Mail poller lock fix, no escalations for closed tickets, webhook retry back-off, SameSite cookies'),
(N'Acme Mobile', N'Platform', N'2.2.1', N'2026-08-05', N'Acme Mobile 2.2.1',
 N'Fixed: replies written offline could be sent twice after reconnecting (offline queue now uses idempotency keys); crash when opening tickets with more than 200 comments on Android 12.',
 N'Offline duplicate replies fix, Android crash fix'),
(N'Acme Mobile', N'Platform', N'2.3.0', N'2026-10-27', N'Acme Mobile 2.3: OIDC sign-in and push setup hints',
 N'New features: single sign-on through OpenID Connect; onboarding hint to disable battery optimisation on Android so push notifications arrive; dark theme. Requires Acme Helpdesk 4.1 or later.',
 N'OIDC SSO for mobile, Android push hint, dark theme');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Releases), @args NVARCHAR(MAX), @r NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SET @args = (SELECT AppName, ModuleName, AppVersion, ReleaseDate, Title, ReleaseNotesContent, KeyHighlights
                 FROM @Releases WHERE Seq = @i FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_AddReleaseNote @ArgsJson = @args, @Result = @r OUTPUT;
    IF @r NOT LIKE N'Release Note for % added successfully%'
        BEGIN DECLARE @m NVARCHAR(2048) = LEFT(@r, 2048); THROW 50101, @m, 1; END;
    SET @i += 1;
END;
PRINT CONCAT(N'Release notes: ', @n);
GO

/* ---------------------------------------------------------------------
   5. Technical documents (several chunks each)
   --------------------------------------------------------------------- */
DECLARE @Docs TABLE (Seq INT IDENTITY, Args NVARCHAR(MAX));

INSERT INTO @Docs (Args) VALUES
(N'{"DocID":"DOC-ARCH-001","AppName":"Acme Helpdesk","ModuleName":"Platform","DocType":"TechnicalDoc","AppVersion":"4.2","DocumentTitle":"Acme Helpdesk architecture overview",
  "Chunks":[
   {"Title":"Components","Breadcrumbs":"Components","MainContent":"Acme Helpdesk consists of the Web app (agent workspace and admin), the Public portal, the API service (REST API v2 and webhooks) and the Acme Worker service. The Worker runs background jobs: inbound mail polling, outbound email, SLA engine, nightly report aggregation and bulk actions. All components share one SQL database.","SearchContext":"What are the parts of Acme Helpdesk? Which service runs background jobs?"},
   {"Title":"Background jobs","Breadcrumbs":"Components > Background jobs","MainContent":"Each background job takes a lock row in the Jobs table so only one Worker instance runs it at a time. Admins can see job status, last run time and release a stuck lock in Admin > System > Background jobs. Since 4.2.1 locks expire automatically after 10 minutes without a heartbeat.","SearchContext":"Job stuck, release lock, background job status"},
   {"Title":"Scaling","Breadcrumbs":"Deployment > Scaling","MainContent":"The Web app and API service are stateless and can run behind a load balancer. Run at least two Worker instances for high availability; job locks prevent double processing. Sticky sessions are not required because sessions are stored in the database."}
  ]}'),
(N'{"DocID":"DOC-API-001","AppName":"Acme Helpdesk","ModuleName":"Integrations","DocType":"TechnicalDoc","AppVersion":"4.2","DocumentTitle":"REST API v2 guide",
  "Chunks":[
   {"Title":"Authentication","Breadcrumbs":"Getting started > Authentication","MainContent":"REST API v2 uses personal or service API tokens sent in the Authorization: Bearer header. Tokens are created in Admin > Integrations > API tokens and can be limited to read-only scopes. Tokens never expire unless an expiry date is set; rotate them at least yearly.","SearchContext":"How to authenticate to the Acme API? API token, bearer header"},
   {"Title":"Pagination","Breadcrumbs":"Reading data > Pagination","MainContent":"List endpoints use cursor-based pagination. Pass page_size (max 500) and follow the next_cursor value from the response. For incremental sync use updated_since with an ISO 8601 timestamp; results are ordered by update time.","SearchContext":"Paging through tickets, next_cursor, incremental sync, updated_since"},
   {"Title":"Rate limits","Breadcrumbs":"Reading data > Rate limits","MainContent":"Each token may send 600 requests per minute. When the limit is exceeded the API returns HTTP 429 with a Retry-After header in seconds. Bulk endpoints (POST /api/v2/tickets/bulk) count as one request regardless of the number of tickets.","SearchContext":"429 Too Many Requests, rate limit, Retry-After"},
   {"Title":"Webhooks","Breadcrumbs":"Webhooks","MainContent":"Webhooks send a POST with a JSON body for ticket events. Each request carries X-Acme-Signature: HMAC-SHA256 of the raw body with the webhook secret. Failed deliveries are retried with exponential back-off for up to 24 hours. Use \"Rotate with grace period\" to change the secret without downtime.","SearchContext":"Webhook signature validation, retries, secret rotation"}
  ]}'),
(N'{"DocID":"DOC-EMAIL-001","AppName":"Acme Helpdesk","ModuleName":"Email Gateway","DocType":"TechnicalDoc","AppVersion":"4.2","DocumentTitle":"Email channel configuration",
  "Chunks":[
   {"Title":"Inbound mailboxes","Breadcrumbs":"Inbound","MainContent":"Inbound mailboxes are polled over IMAP every minute by the Acme Worker, or receive mail through forwarding to the Acme relay address. Incoming messages are matched to existing tickets by the [#ACME-nnnn] subject token and, when enabled, by Message-ID / In-Reply-To headers.","SearchContext":"IMAP polling, email to ticket, threading of replies"},
   {"Title":"Outbound connectors","Breadcrumbs":"Outbound","MainContent":"Outbound email is sent through SMTP connectors. Since 4.2 connectors use OAuth 2.0 client credentials by default; Basic (legacy) authentication with user name and password is still available but not recommended. A failing connector keeps messages in the outbound queue; use Retry queued messages after fixing it.","SearchContext":"SMTP OAuth setup, outbound queue, emails not sent"},
   {"Title":"Deliverability","Breadcrumbs":"Outbound > Deliverability","MainContent":"To avoid spam folders publish SPF and DKIM records for the sending domain and a DMARC policy. Admin > Email > Domains shows the required DNS records and verifies them."}
  ]}'),
(N'{"DocID":"DOC-SLA-001","AppName":"Acme Helpdesk","ModuleName":"SLA Engine","DocType":"TechnicalDoc","AppVersion":"4.2","DocumentTitle":"SLA policies explained",
  "Chunks":[
   {"Title":"Targets","Breadcrumbs":"Concepts > Targets","MainContent":"An SLA policy defines first response and resolution targets per priority. Policies are matched in order; the first policy whose conditions match the ticket applies. Targets are counted in the business hours of the calendar linked to the policy.","SearchContext":"First response time, resolution time, which SLA policy applies"},
   {"Title":"Pause statuses","Breadcrumbs":"Concepts > Pausing","MainContent":"Statuses listed as pause statuses (for example Waiting for customer) stop the resolution timer. The timer resumes when the ticket leaves the status. First response timers are never paused."},
   {"Title":"Escalations","Breadcrumbs":"Escalations","MainContent":"Escalation rules notify a user or group when a target is at risk (for example 80 percent of the time used) or breached. Escalations are evaluated by the SLA engine every 5 minutes; since 4.2.1 the ticket status is re-checked before a notification is sent.","SearchContext":"SLA escalation emails, at risk, breached notification"}
  ]}'),
(N'{"DocID":"DOC-SSO-001","AppName":"Acme Helpdesk","ModuleName":"Authentication","DocType":"TechnicalDoc","AppVersion":"4.2","DocumentTitle":"Single sign-on setup",
  "Chunks":[
   {"Title":"SAML for the web app","Breadcrumbs":"SAML","MainContent":"Acme Helpdesk supports SAML 2.0 for agents. Configure the identity provider with the Entity ID and the Assertion Consumer Service URL from Admin > Security > Single sign-on. The ACS URL must use https. NameID must be the agent email address.","SearchContext":"SAML configuration, ACS URL, NameID email, SSO redirect loop"},
   {"Title":"OIDC for Acme Mobile","Breadcrumbs":"OpenID Connect","MainContent":"Acme Mobile signs in with OpenID Connect. Enable OIDC for mobile and register the redirect URI acme-mobile://auth/callback with the identity provider. The same identity provider can serve both SAML (web) and OIDC (mobile).","SearchContext":"Mobile SSO, OIDC redirect URI"}
  ]}'),
(N'{"DocID":"DOC-MOB-001","AppName":"Acme Mobile","ModuleName":"Platform","DocType":"TechnicalDoc","AppVersion":"2.3","DocumentTitle":"Acme Mobile admin guide",
  "Chunks":[
   {"Title":"Push notifications","Breadcrumbs":"Notifications","MainContent":"Push notifications are delivered through the platform push services. On Android, battery optimisation may stop background delivery; set the app battery mode to Unrestricted. Agents choose which events trigger a push in Profile > Notifications.","SearchContext":"Android push not arriving, battery optimisation"},
   {"Title":"Offline mode","Breadcrumbs":"Offline mode","MainContent":"Acme Mobile caches the last 200 tickets of the agent views. Replies written offline are queued with an idempotency key and sent when the device is online again."}
  ]}');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Docs), @args NVARCHAR(MAX), @r NVARCHAR(MAX);
WHILE @i <= @n
BEGIN
    SELECT @args = Args FROM @Docs WHERE Seq = @i;
    EXEC dbo.sp_AddTechnicalDoc @ArgsJson = @args, @Result = @r OUTPUT;
    IF ISJSON(@r) <> 1
        BEGIN DECLARE @m NVARCHAR(2048) = LEFT(@r, 2048); THROW 50102, @m, 1; END;
    SET @i += 1;
END;
PRINT CONCAT(N'Technical documents: ', @n);
GO

SELECT DocType, COUNT(*) AS Chunks,
       (SELECT COUNT(*) FROM dbo.KnowledgeEmbeddings e JOIN dbo.KnowledgeChunks k2 ON k2.ChunkID = e.ChunkID WHERE k2.DocType = k.DocType) AS Embeddings
FROM dbo.KnowledgeChunks k
GROUP BY DocType;
GO
