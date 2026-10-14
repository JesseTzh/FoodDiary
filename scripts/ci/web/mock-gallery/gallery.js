const cards = [...document.querySelectorAll('.page-card')];
const search = document.querySelector('#search');
const count = document.querySelector('#count');
search.addEventListener('input', () => {
  const query = search.value.trim().toLocaleLowerCase();
  let visible = 0;
  for (const card of cards) {
    card.hidden = !card.dataset.search.toLocaleLowerCase().includes(query);
    if (!card.hidden) visible++;
  }
  count.textContent = `${visible} 个界面`;
  document.querySelector('#empty').hidden = visible > 0;
});
for (const control of document.querySelectorAll('input[name="layout"]')) {
  control.addEventListener('change', () => { document.body.dataset.layout = control.value; });
}
// A directory or deep link must still work when a previous search hid the page.
function revealTarget() {
  const target = document.getElementById(location.hash.slice(1));
  if (target?.classList.contains('page-card') && target.hidden) {
    search.value = '';
    search.dispatchEvent(new Event('input'));
    target.scrollIntoView();
  }
}
window.addEventListener('hashchange', revealTarget);
const viewer = document.querySelector('#viewer');
const viewerImage = document.querySelector('#viewer-image');
for (const link of document.querySelectorAll('.screenshot')) {
  link.addEventListener('click', event => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || !viewer.showModal) return;
    event.preventDefault();
    viewerImage.src = link.href;
    viewerImage.alt = link.dataset.title;
    document.querySelector('#viewer-title').textContent = link.dataset.title;
    document.querySelector('#original').href = link.href;
    viewer.showModal();
    viewer.querySelector('.image-scroll').scrollTop = 0;
  });
}
document.querySelector('#close').addEventListener('click', () => viewer.close());
viewer.addEventListener('click', event => { if (event.target === viewer) viewer.close(); });
