(() => {
  const form = document.querySelector('[data-deletion-form]');
  if (!form) return;

  const accountIdInput = form.querySelector('[name="accountId"]');
  const emailInput = form.querySelector('[name="email"]');
  const detailsInput = form.querySelector('[name="details"]');
  const status = form.querySelector('[data-after-submit]');
  const parameters = new URLSearchParams(window.location.search);
  const accountId = parameters.get('accountId');

  if (accountId && accountIdInput) {
    accountIdInput.value = accountId.slice(0, 255);
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!form.reportValidity()) return;

    const button = form.querySelector('button[type="submit"]');
    const confirmation = form.querySelector('[name="confirmed"]');
    const website = form.querySelector('[name="website"]');
    button.disabled = true;
    button.textContent = 'Sending…';
    status?.classList.add('hidden');
    status?.classList.remove('border-emerald-200', 'bg-emerald-50', 'text-emerald-800', 'border-red-200', 'bg-red-50', 'text-red-700');

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({
          accountId: accountIdInput.value.trim(),
          email: emailInput.value.trim(),
          details: detailsInput?.value.trim() ?? '',
          confirmed: confirmation?.checked ?? false,
          website: website?.value ?? '',
        }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || 'The request could not be sent.');

      form.reset();
      status.textContent = result.message;
      status.classList.remove('hidden');
      status.classList.add('border-emerald-200', 'bg-emerald-50', 'text-emerald-800');
    } catch (error) {
      status.textContent = `${error.message} You can also email support@specterint.com.`;
      status.classList.remove('hidden');
      status.classList.add('border-red-200', 'bg-red-50', 'text-red-700');
    } finally {
      button.disabled = false;
      button.textContent = form.action.endsWith('/data-delete')
        ? 'Send data deletion request'
        : 'Send account deletion request';
    }
  });
})();
