# Cognito: sign-in with email and password (self sign-up, email verification code), a public app
# client for the SPA, a Cognito domain for OAuth, and Google as an identity provider that is
# created only when google_client_id is set. Was infra/auth.yaml (Lab 4).

locals {
  has_google = var.google_client_id != ""
  # Cognito compares redirect URLs exactly, trailing slash included.
  login_urls = flatten([
    for origin in concat(var.local_app_urls, local.frontend_urls) :
    ["${origin}/login", "${origin}/login/"]
  ])
}

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"

  # Users sign in with their email; Cognito emails a code to verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  # Managed login (the hosted sign-in page) needs the Essentials tier; the first 10,000 monthly
  # active users are free.
  user_pool_tier = "ESSENTIALS"

  # Self sign-up stays on: anyone can create an account from the sign-in page.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # A new email (profile page) takes effect only after its code is entered.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  username_configuration {
    case_sensitive = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Mirrored by the signup form (frontend/src/pages/signup-page.tsx).
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_uppercase                = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: no SES setup, limited to about 50 emails a day.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Meetings verification code"
    email_message        = "Your Meetings verification code is {####}"
  }

  # Deleting the pool deletes every account in it. Changing the schema or the username
  # attributes forces replacement, so the plan would fail instead of destroying it.
  lifecycle {
    prevent_destroy = true
  }
}

# Hosted domain for the OAuth endpoints and the managed sign-in page. Prefixes are global.
resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${var.project_name}-${local.account_id}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# Without branding a version 2 domain has no sign-in page to show.
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true

  depends_on = [aws_cognito_user_pool_domain.main]
}

resource "aws_cognito_identity_provider" "google" {
  count = local.has_google ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
    # Filled in by Cognito; listed so that every plan does not offer to remove them.
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Public client (no secret: generate_secret is left unset; setting it on an imported client
# forces replacement): the SPA talks to Cognito directly with SRP.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # A plain reference: the client waits for the Google provider, with no DependsOn.
  supported_identity_providers = concat(
    ["COGNITO"], aws_cognito_identity_provider.google[*].provider_name
  )
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  # aws.cognito.signin.user.admin lets the profile page change the name, email and password.
  allowed_oauth_scopes = ["aws.cognito.signin.user.admin", "email", "openid", "profile"]
  callback_urls        = local.login_urls
  logout_urls          = local.login_urls
}
