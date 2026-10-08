import { useQueryClient } from '@tanstack/react-query'
import { Hub } from 'aws-amplify/utils'
import { signOut as cognitoSignOut } from 'aws-amplify/auth'
import { useEffect, useRef, useState, type ReactNode } from 'react'

import { AuthContext, authConfig, authConfigured, loadUser, type User } from '@/lib/auth'

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const signingOut = useRef(false)
  const [user, setUser] = useState<User | null | undefined>(authConfigured ? undefined : null)

  useEffect(() => {
    if (!authConfigured) return
    let active = true
    const refresh = () => loadUser().then((next) => active && setUser(next))
    refresh()
    // Keeps the state in step with Cognito: the Google redirect, sign-out in another place
    // (e.g. a 401 from the API), or a refresh token that no longer works.
    const stop = Hub.listen('auth', ({ payload }) => {
      if (payload.event === 'signedIn' || payload.event === 'signInWithRedirect') refresh()
      if (payload.event === 'signedOut' || payload.event === 'tokenRefresh_failure') {
        // A deliberate sign-out is about to leave for Cognito's /logout (see signOut below).
        if (signingOut.current) return
        setUser(null)
        // The next user must not see this user's cached meetings.
        queryClient.clear()
      }
    })
    return () => {
      active = false
      stop()
    }
  }, [queryClient])

  const signIn = (next: User) => setUser(next)
  const signOut = async () => {
    signingOut.current = true
    // Clears the local session, then sends the browser to Cognito's /logout, which ends the
    // Cognito session and returns to /login. Do not touch the auth state afterwards: a
    // signed-out state would route to /login at once, and its sign-in redirect would cancel
    // the trip to /logout, leaving the Cognito session alive (you would be signed back in).
    await cognitoSignOut()
    if (!authConfig.domain) {
      setUser(null)
      queryClient.clear()
    }
  }

  return <AuthContext value={{ user, signIn, signOut }}>{children}</AuthContext>
}
