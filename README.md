# Meetings App

List, create, and delete meetings with participants. FastAPI + PostgreSQL backend, React + shadcn/ui frontend, all run with Docker Compose. See [SPEC.md](SPEC.md) for the full specification.

## Quick start

Requires Docker.

```sh
make up      # creates .env from .env.example, builds and starts everything
make seed    # optional: sample participants and meetings
```

- App: http://localhost:3000
- API docs: http://localhost:8000/api/docs

If port 5432 is already in use on your machine, set `DB_PORT` in `.env` (e.g. `DB_PORT=5433`).

## Common commands

Run `make` to list all targets. The most used:

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make logs s=backend` | Follow logs of one service |
| `make test` | Backend tests (in the backend container, against `<db>_test`) |
| `make lint` / `make format` | Ruff + oxlint/Prettier |
| `make migration m="..."` | Autogenerate an Alembic migration |
| `make psql` | Open a psql shell |
| `make clean` | Stop and delete the database volume |

## Local development without rebuilding images

Requires [uv](https://docs.astral.sh/uv/) and Node.js.

```sh
make install        # uv sync + npm install
make dev-backend    # Postgres in Docker, API on :8000 with reload
make dev-frontend   # Vite on :5173, proxies /api to :8000
```

## Deploy to AWS

Everything is described as code in [`infra/`](infra/) and deployed to `us-east-1` by default (`AWS_REGION` in `.env`). Two tools, two roads:

- **Terraform** ([`infra/*.tf`](infra/), see [ADR 0007](docs/adr/0007-terraform.md)): Cognito (`auth.tf`), the weekly report (`reports.tf`) and the agenda parser (`ai.tf`). State and runs are in HCP Terraform (workspace `new-project-solya-dev`). A pull request gets a plan as a check, and a merge to `main` applies it; nobody applies from a laptop.
- **CloudFormation** (`infra/*.yaml`, deployed by the `make deploy-*` scripts): the container registry, the backend with its database, the frontend and the domain certificate.

The CloudFormation parts:

- **Backend** (`make deploy-backend`): the backend container on AWS Lambda (via [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter), so the FastAPI app runs unchanged), exposed through a public **Lambda function URL**, and its PostgreSQL 17 database on **Aurora Serverless v2 scaling between 0 and 1 ACU**. After 5 idle minutes the database pauses and costs only storage; the first request after that waits about 15 seconds while it resumes. The function runs in the database's private subnets; there is no NAT gateway, load balancer or public IP.
- **Frontend** (`make deploy-frontend`): the app, built with `VITE_API_URL` set to the function URL, in a private S3 bucket behind CloudFront on **pay-as-you-go** pricing (no flat-rate plan; `PriceClass_100`). The browser calls the function URL directly; the deploy adds the CloudFront address to the backend's CORS origins.

1. Put the credentials of an IAM user into `.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`; see `.env.example` for the optional settings). `.env` is gitignored.
2. `make deploy` (backend, then frontend). It prints the app and API URLs. The first run takes about 20 minutes (database and CloudFront distribution); later runs take a few minutes. Deploy the two parts separately with `make deploy-backend` / `make deploy-frontend`.
3. `make destroy-frontend` and `make destroy-backend` delete everything except a final database snapshot.

Requires Docker, Node.js, the AWS CLI and Terraform 1.10 or newer. `make infra-lint` checks the templates and the Terraform files.

### Terraform (Cognito, weekly report, agenda parser)

Changes go through a pull request: HCP Terraform posts the plan as a check, and applies it after the merge. From a laptop you only read:

```sh
terraform login        # once: stores an HCP Terraform token
make infra-init        # once: connects infra/ to the workspace
make infra-plan        # what would change (runs in HCP Terraform with its own AWS role)
make infra-output      # user pool id, parser URL, report queue, ...
make cognito-env       # writes the Cognito settings into .env for local development
make report-now WEEK=2026-W43
```

The deploy scripts read the Terraform outputs, so `make deploy-backend` and `make deploy-frontend` need `make infra-init` first. The workspace's variables: `report_email` and `google_client_secret` (sensitive) as Terraform variables, `TFC_AWS_PROVIDER_AUTH=true` and `TFC_AWS_RUN_ROLE_ARN` as environment variables. The role comes from [`infra/bootstrap`](infra/bootstrap/main.tf), applied once from a laptop.

After a backend deploy, the report builder and the parser pick up the new image on the next Terraform run; after the frontend gets a new address, so do Cognito's redirect URLs.

### Custom domain

Once everything is deployed, set the domain in `.env` and attach it:

```sh
DOMAIN_NAME=app.example.com
HOSTED_ZONE_ID=Z0123456789ABC   # optional: only if the domain's DNS is in Route 53
```

```sh
make add-domain
```

This requests an ACM certificate in `us-east-1` (the only region CloudFront accepts), adds the domain to the CloudFront distribution and to the backend's CORS origins. With `HOSTED_ZONE_ID`, the validation and alias records are created in Route 53 for you. Without it, the command prints the validation CNAME to add at your DNS provider, waits for the certificate, and then prints the CNAME that points the domain at CloudFront. Later `make deploy` runs keep the domain. `make remove-domain` detaches it again (to switch domains: `make remove-domain`, change `DOMAIN_NAME`, `make add-domain`).

### Tags

Every AWS resource that supports tags is tagged `PROJECT_NAME=<PROJECT_NAME>` (in the templates as `Key: PROJECT_NAME, Value: !Ref ProjectName`, plus stack tags and tags on the SSM parameter; in Terraform through the AWS provider's `default_tags`). Find the whole app with Resource Groups & Tag Editor, and split out its costs in Billing once `PROJECT_NAME` is activated as a cost allocation tag. `APP_NAME` in older `.env` files still works as the project name.

## Layout

```
backend/    FastAPI app (app/), Alembic migrations (alembic/), tests (tests/)
frontend/   Vite + React + shadcn/ui (src/components/ui is generated by shadcn)
infra/      Terraform (*.tf, bootstrap/), CloudFormation templates and deploy scripts for AWS
```
