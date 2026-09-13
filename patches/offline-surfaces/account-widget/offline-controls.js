/* Layer onto the existing widget/settings DOM; never replace its templates. */
(() => {
  'use strict';
  // Native fallback documents opt in explicitly. Internet status is not proof
  // that the selected server is reachable.
  if (document.documentElement.dataset.ynabOffline !== 'true') return;
  const provider = '.account-widget-api-popular-list button, .account-widget-institution-button, .account-widget-authorization-row';
  const settings = 'body[data-page^="registrations#"] form:not(#change_first_name_form), body[data-page^="registrations#"] a:not(.launch_app_button):not(.page-header__back-link):not(.page-header__close-link)';
  const remote = `${provider}, ${settings}, .project-provider-form`;
  document.body.dataset.offline = 'true';
  const style = document.createElement('style');
  style.textContent = '[data-ynab-server-required="true"]{opacity:.5!important;cursor:not-allowed!important}';
  document.head.append(style);
  function disable() {
    document.querySelectorAll(remote).forEach(element => {
      if (element.dataset.ynabServerRequired !== 'true') {
      element.dataset.ynabServerRequired = 'true';
      element.setAttribute('aria-disabled', 'true');
      element.setAttribute('title', 'Unavailable while the server is unreachable');
      element.setAttribute('tabindex', '-1');
      }
      if ('disabled' in element && !element.disabled) element.disabled = true;
      element.querySelectorAll('input,select,textarea,button').forEach(control => {
        if (!control.disabled) control.disabled = true;
      });
    });
  }
  function block(event) {
    const target = event.target instanceof Element ? event.target : event.target?.parentElement;
    if (!target?.closest('[data-ynab-server-required="true"]')) return;
    if (event.type === 'keydown' && !['Enter', ' '].includes(event.key)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }
  for (const type of ['click', 'submit', 'keydown']) document.addEventListener(type, block, true);
  disable();
  const observer = new MutationObserver(disable);
  window.addEventListener('pagehide', () => observer.disconnect(), {once:true});
  observer.observe(document.body, {childList:true,subtree:true,attributes:true,attributeFilter:['disabled']});
})();
