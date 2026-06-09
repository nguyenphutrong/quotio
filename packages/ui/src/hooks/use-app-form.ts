import type { AnyFormApi, FormOptions } from '@tanstack/react-form';
import { useForm } from '@tanstack/react-form';

type AppFormOptions<TFormData> = Omit<
  FormOptions<
    TFormData,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any,
    // biome-ignore lint/suspicious/noExplicitAny: required by TanStack Form generics
    any
  >,
  'formApi'
> & {
  formApi?: AnyFormApi;
};

export function useAppForm<TFormData>(opts: AppFormOptions<TFormData>) {
  // biome-ignore lint/suspicious/noExplicitAny: TanStack Form internal type mismatch
  return useForm(opts as any);
}

export type { AnyFormApi, FormOptions };
export { useForm };
