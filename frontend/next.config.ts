import type { NextConfig } from "next";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));

const nextConfig: NextConfig = {
  reactStrictMode: true,
  webpack: (config, { webpack }) => {
    config.externals.push("pino-pretty", "lokijs", "encoding");
    // @metamask/sdk optionally imports this for React Native persistence; it's not installed
    // (and not needed) on web, so alias it to an empty module instead of failing the build.
    config.resolve.alias = {
      ...config.resolve.alias,
      "@react-native-async-storage/async-storage": false,
    };
    config.plugins.push(
      // Real baseAccount.js transitively needs @coinbase/cdp-sdk's x402 deps, which aren't
      // installed — stub it at the bundler level; enableBaseAccount:false (context/index.tsx)
      // means it's never actually called at runtime either.
      new webpack.NormalModuleReplacementPlugin(
        /@wagmi\/connectors\/dist\/esm\/baseAccount\.js$/,
        path.join(root, "src/lib/stubs/baseAccount.js")
      ),
      new webpack.NormalModuleReplacementPlugin(
        /@wagmi\/connectors\/dist\/esm\/gemini\.js$/,
        path.join(root, "src/lib/stubs/gemini.js")
      )
    );
    return config;
  },
};

export default nextConfig;
