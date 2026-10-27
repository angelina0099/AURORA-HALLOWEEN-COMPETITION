import { cp, mkdir, readFile, writeFile } from "node:fs/promises";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    "NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are required to build."
  );
}

const html = await readFile("web/index.html", "utf8");
const configuredHtml = html
  .replace("'YOUR_SUPABASE_URL'", JSON.stringify(supabaseUrl))
  .replace("'YOUR_SUPABASE_ANON_KEY'", JSON.stringify(supabaseAnonKey));

if (
  configuredHtml === html ||
  configuredHtml.includes("YOUR_SUPABASE_URL") ||
  configuredHtml.includes("YOUR_SUPABASE_ANON_KEY")
) {
  throw new Error("Supabase configuration placeholders were not found in web/index.html.");
}

await mkdir("dist", { recursive: true });
await writeFile("dist/index.html", configuredHtml);
await cp("web/aurora-logo.png", "dist/aurora-logo.png");
