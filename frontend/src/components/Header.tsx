'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

const links = [
  { href: '/', label: 'Swap' },
  { href: '/liquidity', label: 'Liquidity' },
  { href: '/portfolio', label: 'Portfolio' },
]

export function Header() {
  const pathname = usePathname()

  return (
    <header className="site-header">
      <Link href="/" className="brand">
        BinBook
      </Link>

      <nav className="nav" aria-label="Primary">
        {links.map((l) => {
          const active = l.href === '/' ? pathname === '/' || pathname === '/swap' : pathname === l.href
          return (
            <Link key={l.href} href={l.href} className={active ? 'nav-link active' : 'nav-link'}>
              {l.label}
            </Link>
          )
        })}
      </nav>

      <div className="wallet-slot">
        <appkit-network-button />
        <appkit-button />
      </div>
    </header>
  )
}
