import clsx from 'clsx'
import { Variant } from '../theme/types'
import styles from './Alert.module.css'

type AlertProps = React.ComponentProps<'div'> & {
  /**
   * @default 'info'
   */
  variant?: Variant
  my?: 'sm' | 'md' | 'lg' | null | undefined
}
export default function Alert({ variant = 'info', className, my = 'md', ...props }: AlertProps) {
  return (
    <div
      className={clsx(
        'alert',
        styles.alert,
        `alert--${variant}`,
        my && `margin-top--${my} margin-bottom--${my}`,
        className
      )}
      {...props}
    />
  )
}
