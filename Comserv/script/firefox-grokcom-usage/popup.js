browser.storage.local.get({ current: null, history: [] }).then(function (st) {
    var now = document.getElementById('now');
    var when = document.getElementById('when');
    var hist = document.getElementById('hist');
    if (st.current) {
        now.textContent = 'Build ' + st.current.build + '% · Chat ' + st.current.chat + '%';
        when.textContent = (st.current.at || '') + (st.current.reason ? (' · ' + st.current.reason) : '');
    }
    (st.history || []).slice(-8).reverse().forEach(function (row) {
        var li = document.createElement('li');
        li.textContent = 'Build ' + row.build + '% · Chat ' + row.chat + '% · ' + (row.at || '');
        hist.appendChild(li);
    });
});
