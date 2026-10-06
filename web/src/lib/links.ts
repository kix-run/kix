// Destinations shared by the nav, hero, final call to action, and footer.

/** "Install the Kix CLI": the setup tutorial, which has the install step. */
export const INSTALL_URL = '/docs/tutorials/02-local-setup-and-first-run/';

/** "Read the docs": the first tutorial. */
export const DOCS_URL = '/docs/tutorials/01-orientation/';

/**
 * The one-line installer served from web/install.sh. The command bars that
 * show it in Hero.astro and FinalCta.astro are commented out until the
 * script is published at kix.run/install; see web/HANDOVER.md.
 */
export const INSTALL_COMMAND = 'curl -fsSL https://kix.run/install | sh';
