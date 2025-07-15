import { Variant } from '../theme/types'
import clsx from 'clsx'

interface Props extends React.ComponentProps<'span'> {
  /**
   * @default 'primary'
   */
  variant?: Variant
}
export default function Badge({ variant = 'primary', children, className: classNameProp, ...props }: Props) {
  return (
    <span className={clsx(`badge badge--${variant}`, classNameProp)} {...props}>
      {children}
    </span>
  )
}
