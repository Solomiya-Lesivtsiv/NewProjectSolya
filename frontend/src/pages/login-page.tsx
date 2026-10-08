import { Hub } from 'aws-amplify/utils'
import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router'

import { AuthLayout, AuthNotConfigured } from '@/components/auth-layout'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { authApi, authConfig, authConfigured } from '@/lib/auth'

/**
 * Both ends of the Cognito sign-in. Opened by a visitor it redirects to Cognito's managed login
 * (email and password, sign-up, Continue with Google). When Cognito sends the browser back here
 * with `?code=...`, Amplify exchanges the code for tokens and the router (GuestOnly in App)
 * moves the now signed-in user on; this page only shows progress, or the error.
 */
export function LoginPage() {
  const [params] = useSearchParams()
  // Read once: Amplify removes the code from the URL while it completes the sign-in.
  const [returning] = useState(() => params.has('code') || params.has('error'))
  const [error, setError] = useState<string | null>(() => {
    const failure = params.get('error_description') ?? params.get('error')
    return failure ?? (authConfigured && authConfig.domain ? null : 'Sign-in is not configured')
  })
  const started = useRef(false)

  const start = () => {
    setError(null)
    authApi.startSignIn().catch((e: unknown) => {
      setError(e instanceof Error ? e.message : 'Could not start sign-in')
    })
  }

  useEffect(() => {
    const stop = Hub.listen('auth', ({ payload }) => {
      if (payload.event === 'signInWithRedirect_failure') {
        setError(payload.data?.error?.message ?? 'Sign-in failed')
      }
    })
    return stop
  }, [])

  useEffect(() => {
    // Once only (StrictMode runs effects twice): a second call would replace the saved state
    // that the first redirect is about to need.
    if (started.current || returning || error) return
    started.current = true
    start()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <AuthLayout
      title="Sign in"
      subtitle={returning ? 'Finishing sign-in...' : 'Taking you to the sign-in page...'}
      footer=""
    >
      {!authConfigured && <AuthNotConfigured />}
      {error && (
        <>
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
          {authConfigured && <Button onClick={start}>Try again</Button>}
        </>
      )}
    </AuthLayout>
  )
}
