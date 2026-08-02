/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Shared packages ship raw .ts and are compiled by the consuming app.
  transpilePackages: ["@todoagent/core"],
  eslint: { ignoreDuringBuilds: true },
};

export default nextConfig;
