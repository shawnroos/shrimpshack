import type { BoxProps, ButtonProps, ClientProps, CodeProps, ElementConstructor, ImageProps, InputProps, LinkProps, MarkdownProps, RasterProps, SelectProps, TextProps } from 'claude-code'

import { rasterGradient } from './measure'

const BORDERS = ['single', 'double', 'round', 'bold', 'singleDouble', 'doubleSingle', 'classic']
const SAMPLE_RUST = 'fn greet(name: &str) -> String {\n    format!("hello, {name}")\n}\n\nfn main() {\n    println!("{}", greet("peek"));\n}'
const SAMPLE_DIFF = '@@ -1,3 +1,3 @@\n fn main() {\n-    println!("hi");\n+    println!("hello, peek");\n }'
const SAMPLE_MARKDOWN = '## Markdown\n\nRenders **bold**, *italic*, `code`, [links](https://claude.com) and lists:\n\n- one\n- two\n\n| Element | Use |\n|---|---|\n| Box | layout |\n| Text | words |\n\n```ts\nconst peek = true\n```'

export type GalleryElements = {
  Box: ElementConstructor<BoxProps>
  Text: ElementConstructor<TextProps>
  Button: ElementConstructor<ButtonProps>
  Link: ElementConstructor<LinkProps>
  Code: ElementConstructor<CodeProps>
  Markdown: ElementConstructor<MarkdownProps>
  Input?: ElementConstructor<InputProps>
  Select?: ElementConstructor<SelectProps>
  Image?: ElementConstructor<ImageProps>
  Raster?: ElementConstructor<RasterProps>
  Client?: ElementConstructor<ClientProps>
}

export type GalleryState = { surface: string; width: number; count: number; text: string; border: string; png?: string }

export type GalleryActions = { press: () => void; reset: () => void; type: (value: string) => void; pick: (value: string) => void }

export function UiGallery(elements: GalleryElements, state: GalleryState, act: GalleryActions) {
  const { Box, Text, Button, Link, Code, Markdown, Input, Select, Image, Raster, Client } = elements
  const { width, count, text, border, png } = state
  const heading = (title: string, note: string) => (
    <Box flexDirection="column" marginTop={1}>
      <Text bold color="cyan">{title}</Text>
      <Text dimColor wrap="truncate-end">{note}</Text>
    </Box>
  )

  return (
    <Box flexDirection="column">
      <Text bold>Claude Code UI elements for mods ({state.surface})</Text>
      <Text dimColor>Every element this surface offers, drawn live. ↑↓ scroll.</Text>

      {heading('Text', 'Styles, colours and how long lines are cut')}
      <Box flexDirection="row" gap={1} flexWrap="wrap">
        <Text bold>bold</Text>
        <Text italic>italic</Text>
        <Text underline>underline</Text>
        <Text strikethrough>strike</Text>
        <Text inverse> inverse </Text>
        <Text dimColor>dim</Text>
        <Text color="red">red</Text>
        <Text color="#ff8800">#ff8800</Text>
        <Text backgroundColor="blue" color="white"> on blue </Text>
        <Box key="hover-text">
          <Text hover={{ color: 'magenta', bold: true }}>hover me</Text>
        </Box>
      </Box>
      <Text wrap="truncate-start">truncate-start: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>
      <Text wrap="truncate-middle">truncate-middle: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>
      <Text wrap="truncate-end">truncate-end: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>

      {heading('Box', 'Flexbox layout, borders, padding, background, hover reveal')}
      <Box flexDirection="row" flexWrap="wrap" gap={1}>
        {BORDERS.map(style => (
          <Box key={`border-${style}`} borderStyle={style} borderColor={style === border ? 'green' : 'gray'} paddingX={1}>
            <Text>{style}</Text>
          </Box>
        ))}
      </Box>
      <Box flexDirection="row" justifyContent="space-between" backgroundColor="#202838" paddingX={1}>
        <Text>left</Text>
        <Text>space-between</Text>
        <Text>right</Text>
      </Box>
      <Box key="hover-card" flexDirection="row" borderStyle="round" borderColor="gray" hover={{ borderColor: 'yellow' }} paddingX={1}>
        <Text>Hover this box: its border lights up</Text>
      </Box>

      {heading('Button', 'Click, Enter or its hotkey (g) while the pane has the keys')}
      <Box flexDirection="row" gap={1} flexWrap="wrap">
        <Button key="g-press" label={`Pressed ${count}×`} hotkey="g" variant="primary" onPress={act.press} />
        <Button key="g-reset" label="Reset" variant="secondary" onPress={act.reset} />
        <Button key="g-plain" label="plain" plain onPress={act.press} />
        <Button key="g-dim" label="dim" dimColor onPress={act.press} />
      </Box>

      {heading('Input', 'A text field; Enter submits')}
      {Input ? (
      <Input
        key="g-input"
        label="Say something"
        placeholder="type, then Enter"
        submitLabel="Send"
        onSubmit={act.type}
      />
      ) : (
        <Text dimColor>Not available on this surface.</Text>
      )}
      <Text dimColor>Last submitted: {text || '—'}</Text>

      {heading('Select', 'A pick list; here it chooses which Box border is highlighted')}
      {Select ? (
      <Select
        key="g-select"
        label="Border"
        value={border}
        options={BORDERS.map(style => ({ value: style, label: style }))}
        onSelect={act.pick}
      />
      ) : (
        <Text dimColor>Not available on this surface.</Text>
      )}

      {heading('Link', 'A clickable web link')}
      <Link href="https://docs.claude.com/en/docs/claude-code/overview" label="Claude Code docs" />

      {heading('Code', 'Syntax colours, line numbers, and diff format')}
      <Code source={SAMPLE_RUST} language="rust" path="greet.rs" startLine={1} />
      <Code source={SAMPLE_DIFF} language="rust" format="diff" />

      {heading('Markdown', 'Drawn the way Claude Code draws a reply')}
      <Markdown text={SAMPLE_MARKDOWN} />

      {heading('Image', 'Real pixels, terminal only (kitty / Ghostty graphics)')}
      {Image && png ? (
        <Image key="g-image" source={{ png }} columns={Math.min(40, width)} rows={12} alt="(this terminal cannot draw images)" />
      ) : (
        <Text dimColor>Not available on this surface.</Text>
      )}

      {heading('Raster', 'A raw grid of coloured cells, terminal only')}
      {Raster ? (
        <Raster key="g-raster" columns={Math.min(48, width)} rows={6} cells={rasterGradient(Math.min(48, width), 6)} />
      ) : (
        <Text dimColor>Not available on this surface.</Text>
      )}

      {heading('Client', 'A live mini-app with its own state, timer and keys')}
      {Client ? (
        <Client key="g-client" module="./ticker.tsx" props={{ width: Math.min(40, width) }} />
      ) : (
        <Text dimColor>Not available on this surface.</Text>
      )}
    </Box>
  )
}
