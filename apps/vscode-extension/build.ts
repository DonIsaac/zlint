var isProd = process.env.NODE_ENV === "production";
for (const arg of process.argv) {
    switch (arg) {
        case "--production":
        case "-p":
            isProd = true;
            break;
    }
}

const res = await Bun.build({
    entrypoints: ["src/extension.ts"],
    outdir: "dist",
    external: ["vscode"],
    target: "node",
    format: "cjs",
    sourcemap: "linked",
    minify: isProd && {
        whitespace: false,
        syntax: true,
        identifiers: true
    }
});
for (const log of res.logs) {
    console.log(`[${log.level}] ${log.message}`);
}
if (!res.success) process.exit(1);
