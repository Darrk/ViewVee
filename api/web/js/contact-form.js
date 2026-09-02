(() => {
    const form = document.getElementById('support-form');
    if (!form) return;

    const status = document.getElementById('contact-status');
    const submit = form.querySelector('button[type="submit"]');
    const message = (key) => form.querySelector(`[data-contact-message="${key}"]`)?.textContent.trim() || '';

    form.addEventListener('submit', async (event) => {
        event.preventDefault();
        if (!form.reportValidity()) return;

        submit.disabled = true;
        status.className = 'vv-contact-status';
        status.textContent = message('sending');

        try {
            const response = await fetch(form.action, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(Object.fromEntries(new FormData(form))),
            });
            if (!response.ok) throw new Error(`Support request failed with ${response.status}`);
            form.reset();
            status.classList.add('is-success');
            status.textContent = message('success');
        } catch (_) {
            status.classList.add('is-error');
            status.textContent = message('error');
        } finally {
            submit.disabled = false;
        }
    });
})();