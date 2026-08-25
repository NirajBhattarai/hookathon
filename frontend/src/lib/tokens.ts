import type { Address } from "viem";

export type Category = "Stables" | "Majors" | "L1s" | "DeFi" | "Memes";

export type FaucetToken = {
  symbol: string;
  name: string;
  decimals: number;
  amountLabel: string;
  color: string;
  category: Category;
  address: Address;
};

/** Mock "top tokens" deployed by script/faucet/00_DeployFaucet.s.sol on Sepolia. */
export const FAUCET_TOKENS: FaucetToken[] = [
  {
    symbol: "USDT",
    name: "Tether USD",
    decimals: 6,
    amountLabel: "100K",
    color: "#26A17B",
    category: "Stables",
    address: "0xaed051313220124fb01bffaeea7d559b88f8d15b",
  },
  {
    symbol: "USDC",
    name: "USD Coin",
    decimals: 6,
    amountLabel: "100K",
    color: "#2775CA",
    category: "Stables",
    address: "0x4b8dfabf9389182f33eaac56a8746fed88554e75",
  },
  {
    symbol: "DAI",
    name: "Dai Stablecoin",
    decimals: 18,
    amountLabel: "100K",
    color: "#F5AC37",
    category: "Stables",
    address: "0x50b162f1322196b765c9e8c8eb2fe4942b6c4641",
  },
  {
    symbol: "WBTC",
    name: "Wrapped BTC",
    decimals: 8,
    amountLabel: "10",
    color: "#F7931A",
    category: "Majors",
    address: "0x4cd321bb5d4936097333bce55e8b726db2bdf86d",
  },
  {
    symbol: "WETH",
    name: "Wrapped Ether",
    decimals: 18,
    amountLabel: "50",
    color: "#627EEA",
    category: "Majors",
    address: "0xdc21fdb62477277166410a23ea03ed3d43854e3e",
  },
  {
    symbol: "BNB",
    name: "BNB",
    decimals: 18,
    amountLabel: "200",
    color: "#F0B90B",
    category: "Majors",
    address: "0xcf8d8d3b91d7950eb1d4ec03a8015977b1a4c7a7",
  },
  {
    symbol: "SOL",
    name: "Solana",
    decimals: 9,
    amountLabel: "5K",
    color: "#9945FF",
    category: "Majors",
    address: "0x5109a90d1500f8c349081e0677d2e64225144597",
  },
  {
    symbol: "XRP",
    name: "XRP",
    decimals: 6,
    amountLabel: "200K",
    color: "#23292F",
    category: "Majors",
    address: "0xb3b057934c9aad91d42c8b68fc8b21b793ac011a",
  },
  {
    symbol: "ADA",
    name: "Cardano",
    decimals: 6,
    amountLabel: "500K",
    color: "#0033AD",
    category: "L1s",
    address: "0x0029ec6a2a3ba2768aca4dde75f09e4818831e22",
  },
  {
    symbol: "AVAX",
    name: "Avalanche",
    decimals: 18,
    amountLabel: "2K",
    color: "#E84142",
    category: "L1s",
    address: "0x4f3df722478ff10bb3f71f281e5fc3b5a1ec4f85",
  },
  {
    symbol: "TON",
    name: "Toncoin",
    decimals: 9,
    amountLabel: "10K",
    color: "#0098EA",
    category: "L1s",
    address: "0xd6efafb0552c71125d9a9e61592b0d249e6bc4a4",
  },
  {
    symbol: "TRX",
    name: "TRON",
    decimals: 6,
    amountLabel: "1M",
    color: "#EB0029",
    category: "L1s",
    address: "0x48213c34097884790bbea3ac54158280cbdae96a",
  },
  {
    symbol: "DOT",
    name: "Polkadot",
    decimals: 10,
    amountLabel: "20K",
    color: "#E6007A",
    category: "L1s",
    address: "0xe402e95b883a664b3ddb093aa08d1c1b2dfebd6d",
  },
  {
    symbol: "MATIC",
    name: "Polygon",
    decimals: 18,
    amountLabel: "100K",
    color: "#8247E5",
    category: "L1s",
    address: "0x411f2cdef95263e7dbda6b2fb7475275b12833e1",
  },
  {
    symbol: "ATOM",
    name: "Cosmos",
    decimals: 6,
    amountLabel: "10K",
    color: "#2E3148",
    category: "L1s",
    address: "0xada9c89a9b76d26c6fd6210e53ad72296b758f99",
  },
  {
    symbol: "LINK",
    name: "Chainlink",
    decimals: 18,
    amountLabel: "10K",
    color: "#2A5ADA",
    category: "DeFi",
    address: "0xe29f6b7fe9b3aa3be93fd3cbb724d6e12e1ad885",
  },
  {
    symbol: "UNI",
    name: "Uniswap",
    decimals: 18,
    amountLabel: "5K",
    color: "#FF007A",
    category: "DeFi",
    address: "0xc802ddb2ff7129317b97801a72cd1c14243f7c3a",
  },
  {
    symbol: "DOGE",
    name: "Dogecoin",
    decimals: 8,
    amountLabel: "5M",
    color: "#C2A633",
    category: "Memes",
    address: "0xf0daeb3a5c8ab9d7fc2a89ff44febf3cd3006c1c",
  },
  {
    symbol: "SHIB",
    name: "Shiba Inu",
    decimals: 18,
    amountLabel: "5B",
    color: "#FFA409",
    category: "Memes",
    address: "0xc93fe5cfbaf5f7bd5a7edafb75d679f28c779b50",
  },
  {
    symbol: "PEPE",
    name: "Pepe",
    decimals: 18,
    amountLabel: "10B",
    color: "#3D8130",
    category: "Memes",
    address: "0xd7ecb0f051bfa3f5f20196fb3fdfba4c655cfa31",
  },
];

export const TOKEN_BY_ADDRESS = new Map(FAUCET_TOKENS.map((t) => [t.address.toLowerCase(), t]));

export function tokenByAddress(a: Address): FaucetToken | undefined {
  return TOKEN_BY_ADDRESS.get(a.toLowerCase());
}

export function findToken(symbol: string): FaucetToken {
  const t = FAUCET_TOKENS.find((t) => t.symbol === symbol);
  if (!t) throw new Error(`unknown token ${symbol}`);
  return t;
}
