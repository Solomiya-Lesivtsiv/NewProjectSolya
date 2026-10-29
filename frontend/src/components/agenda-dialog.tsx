import { useEffect, useRef, useState } from 'react'
import { LoaderCircleIcon, PlusIcon, SparklesIcon, Trash2Icon } from 'lucide-react'
import { useFieldArray, useForm, useWatch } from 'react-hook-form'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useSaveAgenda } from '@/hooks/queries'
import {
  agendaParserConfigured,
  ApiError,
  MAX_PASTE_CHARS,
  parseAgenda,
  type AiSuggestion,
  type Meeting,
  type ParsedAgenda,
} from '@/lib/api'

/** Which of a row's fields the model filled, until the user touches them. */
type Suggested = { topic?: boolean; owner?: boolean; minutes?: boolean }
type ActionSuggested = { task?: boolean; owner?: boolean; due?: boolean }

type FormValues = {
  title: string
  titleSuggested: boolean
  items: { topic: string; owner: string; minutes: string; suggested: Suggested }[]
  actions: { task: string; owner: string; due: string; suggested: ActionSuggested }[]
}

const emptyValues: FormValues = { title: '', titleSuggested: false, items: [], actions: [] }

function fromSaved(meeting: Meeting): FormValues {
  const agenda = meeting.agenda
  if (!agenda) return emptyValues
  return {
    title: agenda.title ?? '',
    titleSuggested: false,
    items: agenda.items.map((i) => ({
      topic: i.topic,
      owner: i.owner ?? '',
      minutes: i.minutes?.toString() ?? '',
      suggested: {},
    })),
    actions: agenda.action_items.map((a) => ({
      task: a.task,
      owner: a.owner ?? '',
      due: a.due ?? '',
      suggested: {},
    })),
  }
}

/** The model's answer as form values. Empty stays empty; what it filled is marked. */
function fromParsed(agenda: ParsedAgenda): FormValues {
  return {
    title: agenda.title ?? '',
    titleSuggested: Boolean(agenda.title),
    items: agenda.items.map((i) => ({
      topic: i.topic,
      owner: i.owner ?? '',
      minutes: i.minutes?.toString() ?? '',
      suggested: { topic: true, owner: i.owner != null, minutes: i.minutes != null },
    })),
    actions: agenda.action_items.map((a) => ({
      task: a.task,
      owner: a.owner ?? '',
      due: a.due ?? '',
      suggested: { task: true, owner: a.owner != null, due: a.due != null },
    })),
  }
}

function parseErrorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    switch (error.status) {
      case 401:
        return 'Your session has expired. Sign in again.'
      case 413:
        return `The text is too long (at most ${MAX_PASTE_CHARS.toLocaleString('en')} characters).`
      case 422:
        return 'No agenda was found in this text. You can type it in below.'
      case 429:
        return 'The service is busy. Try again in a moment, or type the agenda below.'
      default:
        return 'The parser is unavailable. You can type the agenda below.'
    }
  }
  return 'Could not reach the parser. Check your connection, or type the agenda below.'
}

function Suggestion() {
  return (
    <Badge variant="secondary" className="h-5 px-2 text-[0.7rem]">
      <SparklesIcon />
      suggested
    </Badge>
  )
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AgendaDialog({ meeting, open, onOpenChange }: Props) {
  const saveAgenda = useSaveAgenda()
  const [pasted, setPasted] = useState('')
  const [parsing, setParsing] = useState(false)
  const [parseError, setParseError] = useState<string | null>(null)
  // What the model returned for this text; sent with Save, so every correction is feedback.
  const [suggestion, setSuggestion] = useState<AiSuggestion | null>(null)
  const controller = useRef<AbortController | null>(null)

  const form = useForm<FormValues>({ defaultValues: emptyValues })
  const items = useFieldArray({ control: form.control, name: 'items' })
  const actions = useFieldArray({ control: form.control, name: 'actions' })
  const values = useWatch({ control: form.control })

  useEffect(() => {
    if (!open) return
    controller.current?.abort()
    setPasted('')
    setParsing(false)
    setParseError(null)
    setSuggestion(null)
    form.reset(meeting ? fromSaved(meeting) : emptyValues)
  }, [open, meeting, form])

  const parse = async () => {
    const abort = new AbortController()
    controller.current = abort
    setParsing(true)
    setParseError(null)
    try {
      const result = await parseAgenda(pasted, abort.signal)
      setSuggestion(result)
      form.reset(fromParsed(result.agenda))
    } catch (error) {
      if (abort.signal.aborted) return
      setParseError(parseErrorMessage(error))
    } finally {
      if (controller.current === abort) setParsing(false)
    }
  }

  const cancelParse = () => {
    controller.current?.abort()
    setParsing(false)
  }

  const close = (next: boolean) => {
    if (!next) controller.current?.abort()
    onOpenChange(next)
  }

  const onSubmit = form.handleSubmit((v) => {
    if (!meeting) return
    if (v.items.length === 0 && v.actions.length === 0) {
      form.setError('root', { message: 'Add at least one agenda item or action item.' })
      return
    }
    saveAgenda.mutate(
      {
        id: meeting.id,
        title: v.title.trim() || null,
        items: v.items.map((i) => ({
          topic: i.topic.trim(),
          owner: i.owner.trim() || null,
          minutes: i.minutes.trim() ? Number(i.minutes) : null,
        })),
        action_items: v.actions.map((a) => ({
          task: a.task.trim(),
          owner: a.owner.trim() || null,
          due: a.due || null,
        })),
        ai_suggestion: suggestion,
      },
      {
        onSuccess: () => {
          toast.success('Agenda saved')
          close(false)
        },
        onError: (error) => form.setError('root', { message: error.message }),
      },
    )
  })

  const tooLong = pasted.length > MAX_PASTE_CHARS
  const unmark = (name: Parameters<typeof form.setValue>[0]) => () =>
    form.setValue(name, false as never)

  return (
    <Dialog open={open && meeting !== null} onOpenChange={close}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{meeting?.agenda ? 'Edit agenda' : 'Add agenda'}</DialogTitle>
          <DialogDescription>
            Paste an email or notes and check what was found, or type the agenda by hand.
          </DialogDescription>
        </DialogHeader>

        <div className="-mx-6 flex flex-col gap-6 overflow-y-auto px-6 py-1">
          {agendaParserConfigured && (
            <Field data-invalid={tooLong}>
              <FieldLabel htmlFor="agenda-paste">Paste an agenda</FieldLabel>
              <Textarea
                id="agenda-paste"
                rows={5}
                value={pasted}
                disabled={parsing}
                onChange={(event) => setPasted(event.target.value)}
                aria-invalid={tooLong}
                placeholder="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв ..."
              />
              {tooLong && (
                <FieldError>
                  {`${pasted.length.toLocaleString('en')} / ${MAX_PASTE_CHARS.toLocaleString('en')} characters: shorten the text.`}
                </FieldError>
              )}
              {parseError && <FieldError>{parseError}</FieldError>}
              <div className="flex items-center gap-3">
                {parsing ? (
                  <>
                    <Button type="button" variant="outline" size="sm" onClick={cancelParse}>
                      Cancel
                    </Button>
                    <span
                      role="status"
                      className="flex items-center gap-2 text-sm text-muted-foreground"
                    >
                      <LoaderCircleIcon className="size-4 animate-spin" />
                      Reading your text. This takes a few seconds...
                    </span>
                  </>
                ) : (
                  <Button
                    type="button"
                    size="sm"
                    disabled={!pasted.trim() || tooLong}
                    onClick={parse}
                  >
                    <SparklesIcon />
                    Parse
                  </Button>
                )}
              </div>
            </Field>
          )}

          <form id="agenda-form" onSubmit={onSubmit} noValidate>
            <FieldGroup>
              {suggestion && (
                <p className="text-sm text-muted-foreground">
                  Fields marked <Suggestion /> come from the text. Check them, then save.
                </p>
              )}

              <Field>
                <FieldLabel htmlFor="agenda-title">
                  Title {values.titleSuggested && <Suggestion />}
                </FieldLabel>
                <Input
                  id="agenda-title"
                  maxLength={200}
                  {...form.register('title', { onChange: unmark('titleSuggested') })}
                />
              </Field>

              <section className="flex flex-col gap-3">
                <h3 className="text-lg">Agenda items</h3>
                {items.fields.map((field, i) => {
                  const marked = values.items?.[i]?.suggested ?? {}
                  const error = form.formState.errors.items?.[i]
                  return (
                    <div
                      key={field.id}
                      className="grid gap-2 rounded-xl bg-card p-3 sm:grid-cols-[1fr_9rem_5rem_auto]"
                    >
                      <Field data-invalid={Boolean(error?.topic)}>
                        <FieldLabel htmlFor={`item-topic-${i}`}>
                          Topic {marked.topic && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`item-topic-${i}`}
                          aria-invalid={Boolean(error?.topic)}
                          {...form.register(`items.${i}.topic`, {
                            required: 'Topic is required',
                            validate: (v) => v.trim() !== '' || 'Topic is required',
                            onChange: unmark(`items.${i}.suggested.topic`),
                          })}
                        />
                        <FieldError errors={[error?.topic]} />
                      </Field>
                      <Field>
                        <FieldLabel htmlFor={`item-owner-${i}`}>
                          Owner {marked.owner && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`item-owner-${i}`}
                          {...form.register(`items.${i}.owner`, {
                            onChange: unmark(`items.${i}.suggested.owner`),
                          })}
                        />
                      </Field>
                      <Field data-invalid={Boolean(error?.minutes)}>
                        <FieldLabel htmlFor={`item-minutes-${i}`}>
                          Min {marked.minutes && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`item-minutes-${i}`}
                          type="number"
                          min={1}
                          max={480}
                          aria-invalid={Boolean(error?.minutes)}
                          {...form.register(`items.${i}.minutes`, {
                            validate: (v) =>
                              v === '' || (Number(v) >= 1 && Number(v) <= 480) || '1 to 480',
                            onChange: unmark(`items.${i}.suggested.minutes`),
                          })}
                        />
                        <FieldError errors={[error?.minutes]} />
                      </Field>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        className="self-end"
                        aria-label={`Remove agenda item ${i + 1}`}
                        onClick={() => items.remove(i)}
                      >
                        <Trash2Icon />
                      </Button>
                    </div>
                  )
                })}
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="self-start"
                  onClick={() => items.append({ topic: '', owner: '', minutes: '', suggested: {} })}
                >
                  <PlusIcon />
                  Add item
                </Button>
              </section>

              <section className="flex flex-col gap-3">
                <h3 className="text-lg">Action items</h3>
                {actions.fields.map((field, i) => {
                  const marked = values.actions?.[i]?.suggested ?? {}
                  const error = form.formState.errors.actions?.[i]
                  return (
                    <div
                      key={field.id}
                      className="grid gap-2 rounded-xl bg-card p-3 sm:grid-cols-[1fr_9rem_9rem_auto]"
                    >
                      <Field data-invalid={Boolean(error?.task)}>
                        <FieldLabel htmlFor={`action-task-${i}`}>
                          Task {marked.task && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`action-task-${i}`}
                          aria-invalid={Boolean(error?.task)}
                          {...form.register(`actions.${i}.task`, {
                            required: 'Task is required',
                            validate: (v) => v.trim() !== '' || 'Task is required',
                            onChange: unmark(`actions.${i}.suggested.task`),
                          })}
                        />
                        <FieldError errors={[error?.task]} />
                      </Field>
                      <Field>
                        <FieldLabel htmlFor={`action-owner-${i}`}>
                          Owner {marked.owner && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`action-owner-${i}`}
                          {...form.register(`actions.${i}.owner`, {
                            onChange: unmark(`actions.${i}.suggested.owner`),
                          })}
                        />
                      </Field>
                      <Field>
                        <FieldLabel htmlFor={`action-due-${i}`}>
                          Due {marked.due && <Suggestion />}
                        </FieldLabel>
                        <Input
                          id={`action-due-${i}`}
                          type="date"
                          {...form.register(`actions.${i}.due`, {
                            onChange: unmark(`actions.${i}.suggested.due`),
                          })}
                        />
                      </Field>
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        className="self-end"
                        aria-label={`Remove action item ${i + 1}`}
                        onClick={() => actions.remove(i)}
                      >
                        <Trash2Icon />
                      </Button>
                    </div>
                  )
                })}
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="self-start"
                  onClick={() => actions.append({ task: '', owner: '', due: '', suggested: {} })}
                >
                  <PlusIcon />
                  Add action item
                </Button>
              </section>

              {form.formState.errors.root && (
                <FieldError>{form.formState.errors.root.message}</FieldError>
              )}
            </FieldGroup>
          </form>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => close(false)}>
            Cancel
          </Button>
          <Button type="submit" form="agenda-form" disabled={saveAgenda.isPending || parsing}>
            {saveAgenda.isPending ? 'Saving...' : 'Save agenda'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
