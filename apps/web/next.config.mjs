/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Shared packages ship raw .ts and are compiled by the consuming app.
  transpilePackages: ["@todoagent/core"],
  eslint: { ignoreDuringBuilds: true },
  // The persistent static-route badge sits over the sidebar's bottom action in
  // development. Keep transient build feedback, but do not let framework chrome
  // make the real Settings link unclickable while the app is being refined.
  devIndicators: { appIsrStatus: false },
};

export default nextConfig;
