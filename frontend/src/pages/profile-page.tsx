import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { ArrowLeftIcon } from 'lucide-react'
import { toast } from 'sonner'
import { Link } from 'react-router'

import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { authApi, loadUser, useAuth } from '@/lib/auth'

export function ProfilePage() {
  const { user, signIn } = useAuth()
  const [name, setName] = useState(user?.name ?? '')
  const [email, setEmail] = useState(user?.email ?? '')
  const [confirmationCode, setConfirmationCode] = useState('')
  const [emailConfirmationPending, setEmailConfirmationPending] = useState(false)
  const [currentPassword, setCurrentPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')

  const updateName = useMutation({
    mutationFn: authApi.updateName,
    onSuccess: (updatedUser) => {
      if (!updatedUser) return
      signIn(updatedUser)
      setName(updatedUser.name)
      toast.success('Name updated')
    },
    onError: (error) => toast.error(error.message),
  })

  const changeEmail = useMutation({
    mutationFn: authApi.changeEmail,
    onSuccess: async ({ needsConfirmation }, nextEmail) => {
      if (needsConfirmation) {
        setEmailConfirmationPending(true)
        toast.info('Enter the verification code sent to your new email address')
        return
      }

      const updatedUser = await loadUser()
      if (updatedUser) signIn(updatedUser)
      setEmail(nextEmail)
      toast.success('Email updated')
    },
    onError: (error) => toast.error(error.message),
  })

  const confirmEmail = useMutation({
    mutationFn: authApi.confirmEmail,
    onSuccess: (updatedUser) => {
      if (updatedUser) signIn(updatedUser)
      setEmailConfirmationPending(false)
      setConfirmationCode('')
      toast.success('Email verified and updated')
    },
    onError: (error) => toast.error(error.message),
  })

  const resendEmailCode = useMutation({
    mutationFn: authApi.resendEmailCode,
    onSuccess: () => toast.success('Verification code sent again'),
    onError: (error) => toast.error(error.message),
  })

  const changePassword = useMutation({
    mutationFn: authApi.changePassword,
    onSuccess: () => {
      setCurrentPassword('')
      setNewPassword('')
      setConfirmPassword('')
      toast.success('Password changed')
    },
    onError: (error) => toast.error(error.message),
  })

  if (!user) return null

  const submitName = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const nextName = name.trim()
    if (!nextName) {
      toast.error('Enter your name')
      return
    }
    updateName.mutate(nextName)
  }

  const submitEmail = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const nextEmail = email.trim()
    if (!nextEmail || nextEmail === user.email) return
    changeEmail.mutate(nextEmail)
  }

  const submitEmailConfirmation = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const code = confirmationCode.trim()
    if (!code) {
      toast.error('Enter the verification code')
      return
    }
    confirmEmail.mutate(code)
  }

  const submitPassword = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (newPassword.length < 8) {
      toast.error('Use at least 8 characters for the new password')
      return
    }
    if (newPassword !== confirmPassword) {
      toast.error('The new passwords do not match')
      return
    }
    changePassword.mutate({ currentPassword, newPassword })
  }

  return (
    <div className="min-h-svh bg-background">
      <header className="flex items-center gap-3 px-4 py-4 md:px-8">
        <Button asChild variant="ghost" size="icon-sm" aria-label="Back to meetings">
          <Link to="/home">
            <ArrowLeftIcon />
          </Link>
        </Button>
        <div>
          <h1 className="font-heading text-2xl leading-none">Profile</h1>
          <p className="mt-1 text-sm text-muted-foreground">Manage your account details</p>
        </div>
      </header>
      <div className="hairline" />

      <main className="mx-auto grid w-full max-w-5xl gap-4 p-4 md:grid-cols-2 md:p-8">
        <Card>
          <CardHeader>
            <CardTitle>Account details</CardTitle>
            <CardDescription>
              Signed in with {user.provider === 'google' ? 'Google' : 'email and password'}.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {user.provider === 'password' ? (
              <div className="grid gap-6">
                <form onSubmit={submitName} className="grid gap-3">
                  <label htmlFor="profile-name" className="text-sm font-medium">
                    Name
                  </label>
                  <Input
                    id="profile-name"
                    autoComplete="name"
                    value={name}
                    onChange={(event) => setName(event.target.value)}
                    required
                    maxLength={100}
                  />
                  <Button type="submit" disabled={updateName.isPending || name.trim() === user.name}>
                    {updateName.isPending ? 'Saving...' : 'Save name'}
                  </Button>
                </form>

                <form onSubmit={submitEmail} className="grid gap-3">
                  <label htmlFor="profile-email" className="text-sm font-medium">
                    Email
                  </label>
                  <Input
                    id="profile-email"
                    type="email"
                    autoComplete="email"
                    value={email}
                    onChange={(event) => setEmail(event.target.value)}
                    required
                  />
                  <Button
                    type="submit"
                    disabled={changeEmail.isPending || email.trim() === user.email}
                  >
                    {changeEmail.isPending ? 'Saving...' : 'Update email'}
                  </Button>
                </form>

                {emailConfirmationPending && (
                  <form onSubmit={submitEmailConfirmation} className="grid gap-3">
                    <label htmlFor="profile-email-code" className="text-sm font-medium">
                      Verification code
                    </label>
                    <Input
                      id="profile-email-code"
                      inputMode="numeric"
                      autoComplete="one-time-code"
                      value={confirmationCode}
                      onChange={(event) => setConfirmationCode(event.target.value)}
                      required
                    />
                    <Button type="submit" disabled={confirmEmail.isPending}>
                      {confirmEmail.isPending ? 'Verifying...' : 'Verify new email'}
                    </Button>
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => resendEmailCode.mutate()}
                      disabled={resendEmailCode.isPending}
                    >
                      {resendEmailCode.isPending ? 'Sending...' : 'Resend code'}
                    </Button>
                  </form>
                )}
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">
                Your name and email are managed by Google and are read-only here.
              </p>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Password</CardTitle>
            <CardDescription>
              {user.provider === 'password'
                ? 'Choose a new password for your account.'
                : 'This account uses Google sign-in, so it has no app password to change.'}
            </CardDescription>
          </CardHeader>
          <CardContent>
            {user.provider === 'password' ? (
              <form onSubmit={submitPassword} className="grid gap-3">
                <label htmlFor="current-password" className="text-sm font-medium">
                  Current password
                </label>
                <Input
                  id="current-password"
                  type="password"
                  autoComplete="current-password"
                  value={currentPassword}
                  onChange={(event) => setCurrentPassword(event.target.value)}
                  required
                />
                <label htmlFor="new-password" className="text-sm font-medium">
                  New password
                </label>
                <Input
                  id="new-password"
                  type="password"
                  autoComplete="new-password"
                  value={newPassword}
                  onChange={(event) => setNewPassword(event.target.value)}
                  minLength={8}
                  required
                />
                <label htmlFor="confirm-password" className="text-sm font-medium">
                  Confirm new password
                </label>
                <Input
                  id="confirm-password"
                  type="password"
                  autoComplete="new-password"
                  value={confirmPassword}
                  onChange={(event) => setConfirmPassword(event.target.value)}
                  minLength={8}
                  required
                />
                <Button type="submit" disabled={changePassword.isPending}>
                  {changePassword.isPending ? 'Changing...' : 'Change password'}
                </Button>
              </form>
            ) : (
              <p className="text-sm text-muted-foreground">
                Change your password through your Google account settings.
              </p>
            )}
          </CardContent>
        </Card>
      </main>
    </div>
  )
}