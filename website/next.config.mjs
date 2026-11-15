/** Static export: the site needs no server. Set NEXT_PUBLIC_BASE_PATH when hosting under a sub-path (e.g. GitHub Pages). */
const basePath = process.env.NEXT_PUBLIC_BASE_PATH || "";
const nextConfig = {
  output: "export",
  basePath,
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: false,
  eslint: { ignoreDuringBuilds: true },
};
export default nextConfig;
