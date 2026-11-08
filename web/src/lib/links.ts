// Destinations shared by the nav, hero, final call to action, and footer.

/** "Install the Kix CLI": the setup tutorial, which has the install step. */
export const INSTALL_URL = '/docs/tutorials/02-local-setup-and-first-run/';

/** "Read the docs": the first tutorial. */
export const DOCS_URL = '/docs/tutorials/01-orientation/';

/**
 * The one-line installer, served from web/public/install. The command bars
 * that show it in Hero.astro and FinalCta.astro stay commented out until
 * kix.run/install serves a signed release; see web/HANDOVER.md.
 */
export const INSTALL_COMMAND = 'curl -fsSL https://kix.run/install | sh';
