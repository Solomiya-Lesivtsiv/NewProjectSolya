# Container diagram (C4, level 2)

Updated for Lab 6: the agenda parser and Amazon Bedrock. The two Lab 6 paths are drawn in bold:
**parse** (browser → agenda parser → Bedrock) returns JSON and writes nothing; **save** (browser →
API → Aurora) is the same validated path as an agenda typed by hand.

```mermaid
C4Container
    title Spry (new-project-solya): containers on AWS, us-east-1

    Person(user, "Team member", "Plans meetings, pastes agendas")

    System_Ext(google, "Google", "Sign-in with Google")
    System_Ext(bedrock, "Amazon Bedrock", "us.amazon.nova-2-lite-v1:0 via Converse; Claude via the Messages API once access is granted")
    System_Ext(ses, "Amazon SES", "Sends the weekly report email")

    Container(spa, "Web app", "React, Vite; S3 + CloudFront", "Meetings, agenda form, Paste an agenda")
    Container(cognito, "User pool", "Amazon Cognito", "Managed login, ID tokens (JWT)")

    Container_Boundary(vpc, "VPC, private subnets, no NAT") {
        Container(api, "API", "FastAPI on Lambda, function URL", "Meetings and agendas; validates and checks ownership")
        ContainerDb(db, "Database", "Aurora PostgreSQL Serverless v2", "Meetings, agenda, ai_suggestion (JSONB)")
        Container(builder, "Report builder", "Lambda, same image", "Builds the weekly CSV")
    }

    Container(parser, "Agenda parser", "FastAPI on Lambda, function URL, outside the VPC", "Text → validated agenda JSON; no database, never writes")
    Container(schedule, "Schedule + queue", "EventBridge Scheduler, SQS", "Weekly trigger")
    ContainerDb(reports, "Reports bucket", "Amazon S3", "Weekly CSV files")
    Container(mailer, "Report mailer", "Lambda, outside the VPC", "Emails a new report")

    Rel(user, spa, "Uses", "HTTPS")
    Rel(spa, cognito, "Signs in", "OAuth 2.0 code + PKCE")
    Rel(cognito, google, "Federates to")

    Rel(spa, parser, "1. parse: pasted text, today, tz", "HTTPS POST + ID token")
    Rel(parser, bedrock, "record_agenda tool call", "IAM, Converse")
    Rel(spa, api, "2. save: agenda + ai_suggestion", "HTTPS PUT + ID token")
    Rel(api, db, "Reads, writes", "SQL")

    Rel(schedule, builder, "Starts", "SQS")
    Rel(builder, db, "Reads", "SQL")
    Rel(builder, reports, "Writes CSV")
    Rel(reports, mailer, "Object created", "S3 event")
    Rel(mailer, ses, "Sends email")

    UpdateRelStyle(spa, parser, $textColor="#b5179e", $lineColor="#b5179e")
    UpdateRelStyle(parser, bedrock, $textColor="#b5179e", $lineColor="#b5179e")
    UpdateRelStyle(spa, api, $textColor="#0b7285", $lineColor="#0b7285")
```

Why the parser is outside the VPC while the API and the report builder are inside: it needs no
database, so it reaches Bedrock over the internet without a NAT gateway or a VPC interface
endpoint ($7.30 a month each), and costs nothing while nobody uses it. See
[ADR 0006](../adr/0006-llm-agenda-parsing.md).
