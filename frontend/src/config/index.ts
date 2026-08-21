import { WagmiAdapter } from '@reown/appkit-adapter-wagmi'
import { cookieStorage, createStorage } from 'wagmi'
import { defaultNetwork, networks } from './chains'

export const projectId =
  process.env.NEXT_PUBLIC_REOWN_PROJECT_ID || 'b56e18d47c72ab683b10814fe9495694'

export const metadata = {
  name: process.env.NEXT_PUBLIC_APP_NAME || 'BinBook',
  description:
    process.env.NEXT_PUBLIC_APP_DESCRIPTION || 'Bin-based Uniswap v4 liquidity book',
  url: process.env.NEXT_PUBLIC_APP_URL || 'http://localhost:3000',
  icons: [process.env.NEXT_PUBLIC_APP_ICON || 'http://localhost:3000/favicon.ico'],
}

export const wagmiAdapter = new WagmiAdapter({
  storage: createStorage({ storage: cookieStorage }),
  ssr: true,
  projectId,
  networks,
})

export const config = wagmiAdapter.wagmiConfig

export { networks, defaultNetwork }
