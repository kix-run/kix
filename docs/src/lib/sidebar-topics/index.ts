/// <reference path="./locals.d.ts" />

import type { StarlightPlugin, StarlightUserConfig } from '@astrojs/starlight/types'
import { z } from 'astro/zod'

import {
  StarlightSidebarTopicsConfigSchema,
  StarlightSidebarTopicsOptionsSchema,
  type StarlightSidebarTopicsUserConfig,
  type StarlightSidebarTopicsUserOptions,
} from './libs/config'
import { throwPluginError } from './libs/plugin'
import { vitePluginStarlightSidebarTopics } from './libs/vite'

export type {
  StarlightSidebarTopicsConfig,
  StarlightSidebarTopicsUserConfig,
  StarlightSidebarTopicsOptions,
  StarlightSidebarTopicsUserOptions,
} from './libs/config'

export default function starlightSidebarTopicsPlugin(
  userConfig: StarlightSidebarTopicsUserConfig,
  userOptions?: StarlightSidebarTopicsUserOptions,
): StarlightPlugin {
  const parsedConfig = StarlightSidebarTopicsConfigSchema.safeParse(userConfig)

  if (!parsedConfig.success) {
    throwPluginError(
      `The provided plugin configuration is invalid.\n${parsedConfig.error.issues.map((issue) => issue.message).join('\n')}`,
    )
  }

  const parsedOptions = StarlightSidebarTopicsOptionsSchema.safeParse(userOptions)

  if (!parsedOptions.success) {
    throwPluginError(
      `Invalid starlight-sidebar-topics configuration:

${z.prettifyError(parsedOptions.error)}
`,
    )
  }

  const config = parsedConfig.data
  const options = parsedOptions.data

  return {
    name: 'starlight-sidebar-topics',
    hooks: {
      'config:setup'({ addIntegration, addRouteMiddleware, command, config: starlightConfig, updateConfig }) {
        if (command !== 'dev' && command !== 'build') return

        // VENDOR MOD 1: removed the "sidebar already configured" guard.
        // The plugin must run *first* in the plugins array (so its
        // updateConfig sets the topic-grouped sidebar before
        // starlight-versions wraps it), so the guard would never fire
        // under our usage anyway. Removed to make the architectural
        // contract explicit and unblock any future composition.

        // VENDOR MOD 2: changed `order: 'pre'` to `order: 'post'`.
        // starlight-versions registers its middleware at the default
        // bucket. Its middleware unwraps `starlightRoute.sidebar` from
        // the per-version wrapper to the items of the current version.
        // We need to run AFTER that unwrap so we see flat topic groups.
        // Pre → default → post is the Starlight ordering (see
        // @astrojs/starlight/utils/plugins.ts applyPluginMiddleware).
        addRouteMiddleware({
          entrypoint: new URL('./middleware.ts', import.meta.url).href,
          order: 'post',
        })

        const sidebar: StarlightUserConfig['sidebar'] = []

        for (const [index, topic] of config.entries()) {
          if ('items' in topic) {
            sidebar.push({ label: String(index), items: topic.items })
          }
        }
        updateConfig({
          components: {
            Sidebar: new URL('./overrides/Sidebar.astro', import.meta.url).href,
            ...starlightConfig.components,
          },
          sidebar,
        })

        addIntegration({
          name: 'starlight-sidebar-topics-integration',
          hooks: {
            'astro:config:setup': ({ updateConfig }) => {
              updateConfig({ vite: { plugins: [vitePluginStarlightSidebarTopics(config, options)] } })
            },
          },
        })
      },
    },
  }
}
