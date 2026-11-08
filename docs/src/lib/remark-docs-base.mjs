// Pages link to each other as `/docs/...`. A build served under another
// base (`/docs/main`, `/docs/v0.5`; see astro.config.mjs) rewrites those
// links to its own base, so each version's pages link within that version.
import { visit } from 'unist-util-visit';

const written = '/docs';

export default function remarkDocsBase({ base }) {
  const target = base.replace(/\/+$/, '');
  const rewrite = (url) =>
    url === written || url.startsWith(`${written}/`) || url.startsWith(`${written}#`)
      ? target + url.slice(written.length)
      : url;

  return (tree) => {
    if (target === written) return;
    visit(tree, (node) => {
      if ((node.type === 'link' || node.type === 'definition') && typeof node.url === 'string') {
        node.url = rewrite(node.url);
      }
      if (node.type === 'mdxJsxFlowElement' || node.type === 'mdxJsxTextElement') {
        for (const attribute of node.attributes ?? []) {
          if (attribute.type === 'mdxJsxAttribute' && attribute.name === 'href' && typeof attribute.value === 'string') {
            attribute.value = rewrite(attribute.value);
          }
        }
      }
    });
  };
}
