"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const links = [
  { href: "/", label: "Swap", prefetch: true },
  { href: "/liquidity", label: "Liquidity", prefetch: false },
  { href: "/portfolio", label: "Portfolio", prefetch: false },
  { href: "/faucet", label: "Faucet", prefetch: false },
  { href: "/custom-token", label: "Launch", prefetch: false },
  { href: "/docs", label: "Docs", prefetch: true },
] as const;

export function Header() {
  const pathname = usePathname();

  return (
    <header className="site-header">
      <Link href="/" className="brand">
        BinBook
      </Link>

      <nav className="nav" aria-label="Primary">
        {links.map((l) => {
          const active =
            l.href === "/" ? pathname === "/" || pathname === "/swap" : pathname === l.href;
          return (
            <Link
              key={l.href}
              href={l.href}
              prefetch={l.prefetch}
              className={active ? "nav-link active" : "nav-link"}
            >
              {l.label}
            </Link>
          );
        })}
      </nav>

      <div className="wallet-slot">
        <appkit-network-button />
        <appkit-button />
      </div>
    </header>
  );
}
