import type { MetadataRoute } from "next";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: "https://todoagent.space",
      lastModified: new Date("2026-08-17T00:00:00.000Z"),
      changeFrequency: "weekly",
      priority: 1,
    },
  ];
}
