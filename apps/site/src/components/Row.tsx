import clsx from 'clsx'
import styles from './Row.module.css'
import React from 'react'

type Props = React.ComponentProps<'div'>
const FlexRow = React.forwardRef<HTMLDivElement, Props>(function Row({ className, ...props }, ref) {
  return <div {...props} className={clsx(styles.flexRow, className)} ref={ref} />
})
export default FlexRow
