export const FULL_OG = `<!doctype html>
<html><head>
<meta charset="utf-8">
<title>Fallback title</title>
<meta content="Cats &amp; dogs" property="og:title">
<meta property="og:description" content="All about pets">
<meta property='og:site_name' content='Pet Site'>
<meta property="og:image" content="/img/card.png">
<link rel="icon" href="/static/icon.png">
</head><body><h1>Pets</h1><p>Readable text here.</p><script>var x = 1</script></body></html>`

export const TITLE_ONLY = `<html><head>
<title>  Plain   page </title>
<meta name="description" content="A short summary">
</head><body><p>Hello</p></body></html>`

export const NO_ICON = `<html><head><title>No icon</title></head><body>Text</body></html>`

export const ICO_ICON = `<html><head><title>Ico</title><link rel="shortcut icon" href="https://cdn.ico.test/favicon.ico"></head><body>x</body></html>`

export const HOSTILE = `<html><head><title>Hostile</title>
<meta property="og:image" content="file:///etc/passwd">
<link rel="icon" href="gopher://127.0.0.1:6379/">
</head><body>x</body></html>`

export function privateImage(image: string): string {
  return `<html><head><title>Public</title><meta property="og:image" content="${image}"><link rel="icon" href="${image}"></head><body>x</body></html>`
}
