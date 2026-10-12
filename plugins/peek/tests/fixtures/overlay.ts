type Node = { type?: string; props?: { key?: string; module?: string; position?: string; children?: unknown }; children?: unknown }

const childrenOf = (node: Node): unknown[] => {
  const kids = node.children ?? node.props?.children
  return Array.isArray(kids) ? kids : kids === undefined || kids === null ? [] : [kids]
}

const hoverLayerIn = (node: unknown): string | undefined => {
  if (!node || typeof node !== 'object') return undefined
  const one = node as Node
  if (one.type === 'Client' && /hover-layer/.test(one.props?.module ?? '')) return one.props?.key
  for (const kid of childrenOf(one)) {
    const key = hoverLayerIn(kid)
    if (key) return key
  }
  return undefined
}

// An absolute Box paints over the siblings before it and under the ones after it, so an overlay must be its parent's last child.
export function hoverLayers(tree: unknown): { onTop: string[]; buried: string[] } {
  const found = { onTop: [] as string[], buried: [] as string[] }
  const walk = (node: unknown) => {
    if (!node || typeof node !== 'object') return
    const kids = childrenOf(node as Node).filter(kid => kid && typeof kid === 'object')
    kids.forEach((kid, j) => {
      const one = kid as Node
      const key = one.type === 'Box' && one.props?.position === 'absolute' ? hoverLayerIn(one) : undefined
      if (key) (j === kids.length - 1 ? found.onTop : found.buried).push(key)
      else walk(kid)
    })
  }
  walk(tree)
  return found
}
