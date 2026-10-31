# Non-secret values only. Secrets and personal data are workspace variables in HCP Terraform:
#   google_client_secret (sensitive), report_email
project_name = "new-project-solya"
region       = "us-east-1"

# Public by design: the browser sees it on every Google sign-in.
google_client_id = "301341939384-stt8qfvofaees3rqecsa7ncte93o52sd.apps.googleusercontent.com"

parser_provider = "converse"
parser_model    = "us.amazon.nova-2-lite-v1:0"
