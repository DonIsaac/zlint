import React, { JSX, PropsWithChildren } from 'react'
import Link from '@docusaurus/Link'
import clsx from 'clsx'
import styles from './Button.module.css'
import { Size, Variant } from '../theme/types'

interface BaseButtonProps {
  size?: Size
  variant?: Variant
  outline?: boolean
}
interface LinkButtonProps extends BaseButtonProps, React.ComponentProps<typeof Link> {
  href: string
  as?: never
}
interface ButtonButtonProps extends BaseButtonProps, React.HTMLAttributes<HTMLButtonElement> {
  href?: never
  as?: React.ComponentType<BaseButtonProps>
}

export type ButtonProps = LinkButtonProps | ButtonButtonProps

export default function Button({
  children,
  as,
  href,
  size = 'lg',
  variant = 'primary',
  outline,
  className: classNameProp,
  ...props
}: ButtonProps): JSX.Element {
  const Component = as ?? href ? Link : 'button'
  const className = clsx(
    'button',
    size && `button--${size}`,
    variant && `button--${variant}`,
    {
      'button--outline': outline,
    },
    styles.flexButton,
    classNameProp
  )
  return (
    <Component {...(props as any)} to={href} className={className}>
      {children}
    </Component>
  )
}

Button.Row = function ButtonRow({ children }: PropsWithChildren) {
  return <div className={styles.buttonRow}>{children}</div>
}
