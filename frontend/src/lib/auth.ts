import { useMutation } from '@tanstack/react-query'
import { Amplify } from 'aws-amplify'
import {
  confirmUserAttribute,
  fetchAuthSession,
  sendUserAttributeVerificationCode,
  signInWithRedirect,
  updatePassword,
  updateUserAttribute,
} from 'aws-amplify/auth'
import { createContext, useContext } from 'react'

export type User = {
  name: string
  email: string
  provider: 'password' | 'google'
}

export type PasswordChangeData = { currentPassword: string; newPassword: string }

// Public Cognito ids, baked in at build time (make deploy-auth writes them to .env).
const env = import.meta.env
export const authConfig = {
  userPoolId: env.COGNITO_USER_POOL_ID ?? '',
  clientId: env.COGNITO_CLIENT_ID ?? '',
  domain: env.COGNITO_DOMAIN ?? '',
}
export const authConfigured = Boolean(authConfig.userPoolId && authConfig.clientId)

export function configureAuth() {
  if (!authConfigured) return
  // Cognito only redirects back to URLs listed in infra/auth.yaml, and compares them exactly:
  // <origin>/login and <origin>/login/. Amplify picks the one that matches the current page.
  const redirect = [`${window.location.origin}/login`, `${window.location.origin}/login/`]
  Amplify.configure({
    Auth: {
      Cognito: {
        userPoolId: authConfig.userPoolId,
        userPoolClientId: authConfig.clientId,
        loginWith: {
          email: true,
          ...(authConfig.domain && {
            oauth: {
              domain: authConfig.domain,
              scopes: ['openid', 'email', 'profile', 'aws.cognito.signin.user.admin'],
              redirectSignIn: redirect,
              redirectSignOut: redirect,
              responseType: 'code',
            },
          }),
        },
      },
    },
  })
}

// Cognito's exception names -> messages for people.
const MESSAGES: Record<string, string> = {
  AliasExistsException: 'An account with this email already exists',
  CodeMismatchException: 'That code is not right; check the email and try again',
  ExpiredCodeException: 'That code has expired; send a new one',
  LimitExceededException: 'Too many attempts; wait a few minutes and try again',
  TooManyRequestsException: 'Too many attempts; wait a few minutes and try again',
  InvalidPasswordException: 'Use at least 8 characters, with a lowercase letter and a number',
}

function friendly(error: unknown): Error {
  if (error instanceof Error) return new Error(MESSAGES[error.name] ?? error.message)
  return new Error('Something went wrong')
}

async function withFriendlyErrors<T>(action: () => Promise<T>): Promise<T> {
  try {
    return await action()
  } catch (error) {
    throw friendly(error)
  }
}

/** The signed-in user from the (auto-refreshed) ID token, or null. */
export async function loadUser(): Promise<User | null> {
  if (!authConfigured) return null
  try {
    const claims = (await fetchAuthSession()).tokens?.idToken?.payload
    if (!claims) return null
    const email = String(claims.email ?? '')
    return {
      name: String(claims.name ?? email.split('@')[0]),
      email,
      // Federated (Google) accounts carry an "identities" claim.
      provider: claims.identities ? 'google' : 'password',
    }
  } catch {
    return null
  }
}

/** The ID token the API expects (`Authorization: Bearer ...`); Amplify refreshes it. */
export async function getIdToken(): Promise<string | null> {
  if (!authConfigured) return null
  try {
    return (await fetchAuthSession()).tokens?.idToken?.toString() ?? null
  } catch {
    return null
  }
}

/** Fresh tokens, so the new name or email reaches the API (it copies them from the ID token). */
async function reloadUser(): Promise<User | null> {
  await fetchAuthSession({ forceRefresh: true })
  return loadUser()
}

export const authApi = {
  /** Leaves the page for Cognito's managed login (email and password, or Google). */
  startSignIn: () => signInWithRedirect(),

  // Profile changes (password accounts only: Google sets the name and email on every sign-in).
  updateName: (name: string) =>
    withFriendlyErrors(async () => {
      await updateUserAttribute({ userAttribute: { attributeKey: 'name', value: name } })
      return reloadUser()
    }),
  /** Cognito emails a code to the new address; the email changes once `confirmEmail` checks it. */
  changeEmail: (email: string) =>
    withFriendlyErrors(async () => {
      const { nextStep } = await updateUserAttribute({
        userAttribute: { attributeKey: 'email', value: email },
      })
      return { needsConfirmation: nextStep.updateAttributeStep === 'CONFIRM_ATTRIBUTE_WITH_CODE' }
    }),
  confirmEmail: (code: string) =>
    withFriendlyErrors(async () => {
      await confirmUserAttribute({ userAttributeKey: 'email', confirmationCode: code })
      return reloadUser()
    }),
  resendEmailCode: () =>
    withFriendlyErrors(() =>
      sendUserAttributeVerificationCode({ userAttributeKey: 'email' }).then(() => undefined),
    ),
  changePassword: async ({ currentPassword, newPassword }: PasswordChangeData) => {
    try {
      await updatePassword({ oldPassword: currentPassword, newPassword })
    } catch (error) {
      // Here it means the current password is wrong, not the email.
      if (error instanceof Error && error.name === 'NotAuthorizedException') {
        throw new Error('Current password is wrong')
      }
      throw friendly(error)
    }
  },
}

export type AuthContextValue = {
  /** undefined while the stored session is being checked. */
  user: User | null | undefined
  signIn: (user: User) => void
  signOut: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue | null>(null)

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used inside <AuthProvider>')
  return value
}

/** Puts the updated user (from the refreshed token) into the auth state. */
function useUserUpdate<T>(mutationFn: (input: T) => Promise<User | null>) {
  const { signIn } = useAuth()
  return useMutation({ mutationFn, onSuccess: (user) => user && signIn(user) })
}

export function useUpdateName() {
  return useUserUpdate(authApi.updateName)
}

export function useChangeEmail() {
  return useMutation({ mutationFn: authApi.changeEmail })
}

export function useConfirmEmail() {
  return useUserUpdate(authApi.confirmEmail)
}

export function useResendEmailCode() {
  return useMutation({ mutationFn: authApi.resendEmailCode })
}

export function useChangePassword() {
  return useMutation({ mutationFn: authApi.changePassword })
}
