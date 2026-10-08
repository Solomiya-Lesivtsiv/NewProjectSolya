import type { ReactNode } from 'react'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'

type Props = {
  title: string
  subtitle: string
  children: ReactNode
  footer: ReactNode
}

/** Centered card for the login page; tightens on short screens so it fits without scrolling. */
export function AuthLayout({ title, subtitle, children, footer }: Props) {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center-safe bg-[radial-gradient(ellipse_at_top,#fef4f6,transparent_60%)] px-4 py-6 short:py-3">
      <div className="flex w-full max-w-md flex-col gap-4 short:gap-3">
        <div className="flex flex-col items-center gap-1 text-center">
          <p className="flex items-center gap-2 text-xs font-semibold tracking-[0.2em] text-muted-foreground uppercase short:hidden">
            <span className="dot" />
            Meetings
            <span className="dot" />
          </p>
          <h1 className="text-4xl leading-tight">{title}</h1>
          <p className="font-serif text-lg text-muted-foreground italic short:hidden">{subtitle}</p>
        </div>
        <div className="flex flex-col gap-4 rounded-[28px] bg-card px-6 py-6 sm:px-8 short:gap-3 short:py-4">
          {children}
        </div>
        <p className="text-center text-sm text-muted-foreground">{footer}</p>
      </div>
    </div>
  )
}

/** Shown when the build has no Cognito ids. */
export function AuthNotConfigured() {
  return (
    <Alert variant="destructive">
      <AlertTitle>Sign-in is not configured</AlertTitle>
      <AlertDescription>
        Run <code>make deploy-auth</code>, then rebuild the app (<code>make up</code>).
      </AlertDescription>
    </Alert>
  )
}
