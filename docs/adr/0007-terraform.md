# 7. Terraform with HCP Terraform for Cognito, the weekly report and the agenda parser

Status: accepted (2026-10-31)

## Context

Labs 4-6 added three CloudFormation stacks, deployed from a laptop by shell scripts:
`auth` (Cognito), `reports` (schedule, queue, builder, bucket, mailer, SES) and `ai` (the agenda
parser). They worked, but the infrastructure was changed by whoever ran `make deploy-*` with
admin keys, nothing reviewed the change before it reached AWS, and the project already reaches
outside AWS (the Google OAuth client, GitHub) where CloudFormation cannot follow. A second
environment (stage) is coming, and copying stacks by hand would let the two drift apart.

The resources hold data that must survive the move: the user pool holds every account since
Lab 4, the bucket every report since Lab 5.

## Decision

- **Terraform, in one root module in `infra/`** (`auth.tf`, `reports.tf`, `ai.tf`, plus
  `variables.tf`, `data.tf`, `outputs.tf`). The older stacks (ECR, backend + Aurora, frontend,
  certificate) stay CloudFormation for now; Terraform reads their outputs with
  `aws_cloudformation_stack` data sources.
- **State and runs in HCP Terraform**, workspace `new-project-solya-dev`, connected to the GitHub
  repository with `infra` as its working directory. A pull request gets a speculative plan as a
  check; a merge to `main` plans and applies. The `Makefile` has `infra-plan`, `infra-output`
  and `infra-init`, and deliberately no `apply`.
- **No AWS keys in HCP Terraform.** Each run gets an OIDC token from HCP Terraform and exchanges
  it for temporary credentials of `hcp-terraform-<org>` (`infra/bootstrap`, applied once from a
  laptop). Its trust allows only this workspace.
- **Adopted, not re-created.** All 26 CloudFormation resources got `DeletionPolicy: Retain`,
  the stacks were deleted, and `import` blocks handed the resources to Terraform: 36 Terraform
  resources (the bucket's settings, inline IAM policies and policy attachments are separate
  resources in Terraform). The first plan was `36 to import, 0 to add, 3 to change, 0 to destroy`.
  The three changes were safe in place: the report builder moved to the current backend image
  (it was two weeks behind), the mailer's code was uploaded again (same `index.py`, a different
  zip), and the Google provider was re-sent its unchanged secret, now marked sensitive. Names
  were kept, including the role names CloudFormation generated. Nothing was re-created.
- **Guard rails on data.** `prevent_destroy` on the user pool and the reports bucket: a change
  that forces their replacement fails at plan instead of deleting accounts or reports.

## Alternatives considered

- **Stay on CloudFormation.** AWS keeps the state, and failed updates roll back on their own.
  It lost because it stops at the AWS account boundary (the Google OAuth client and GitHub
  settings cannot be in the same plan) and because the review step (change sets) is optional,
  where Terraform's plan is the centre of the workflow.
- **AWS CDK.** Real code, loops and types, but it synthesises CloudFormation, so it inherits the
  same AWS-only boundary, and adds a TypeScript or Python build to the infrastructure.
- **OpenTofu.** The same language and commands under an open-source licence. It would work here
  unchanged; HCP Terraform, which the course uses for state and runs, is HashiCorp's, so the
  project uses Terraform. Moving later is a matter of the binary and the backend.
- **State in S3 with a lock file.** Free, and in the same account, but the project would also
  need a pipeline to run plans and applies with OIDC. HCP Terraform gives state, locking,
  history and runs in one place on its free tier.

## Consequences

- **Who can change the infrastructure:** anyone who can merge to `main`, through a reviewed pull
  request whose plan is visible in the check. Applying from a laptop is for emergencies only and
  needs the workspace switched to local execution.
- **Where the secrets are.** The Google client secret is a sensitive workspace variable; the
  database password is read from SSM Parameter Store. Both end up in plain text in the state (in
  the identity provider and in the builder's `DATABASE_URL`), which is why the state is in HCP
  Terraform, encrypted and access-controlled, and never in Git. `sensitive` only hides them in
  plan output. The report email is a workspace variable too, because the repository is public.
- **Two roads.** The backend image is still built and deployed by `make deploy-backend` (or the
  pipeline); the builder and the parser follow that image on the next Terraform run, because
  `data.aws_lambda_function.api` reads it. When a change needs both, Terraform goes first for new
  resources and settings; the application deploy follows. Cognito's redirect URLs follow a new
  frontend address on the next Terraform run, no longer from `deploy-frontend.sh`.
- **When HCP Terraform is down,** nothing that runs stops: the app, the database, the report and
  the parser do not depend on it. Only infrastructure changes wait. In an emergency the state can
  be pulled (`terraform state pull`) and a change applied locally with the workspace locked.
- **Drift is visible on every plan.** A fix made in the console at 23:00 shows up as a change in
  the next plan, which would undo it; the fix has to be written into the `.tf` files the next
  morning, through a pull request, before anyone applies.
- **No automatic rollback.** A run that fails halfway leaves the created resources in the state;
  the fix is a new commit and another apply.
