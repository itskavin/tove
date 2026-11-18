/// Round 4 fixtures: a server-health reply built from the dashboard
/// blocks, an HTML company profile in the reference's style (all pictures
/// on example domains), and a mixed reply (prose, HTML and a dashboard
/// block) to show they read as one response.
library;

const healthReply =
    '''Everything important is up. One disk is filling and Seerr is slow.

```hermes-ui
{"v":1,"type":"status","title":"Homelab","state":"warn","summary":"2 warnings, no outages","updated":"just now"}
```

```hermes-ui
{"v":1,"type":"gauges","items":[{"label":"CPU","value":23},{"label":"Memory","value":61,"sub":"9.8 of 16 GB"},{"label":"Disk /srv","value":91,"tone":"bad"},{"label":"Battery","value":100,"tone":"good","sub":"On AC"}]}
```

```hermes-ui
{"v":1,"type":"metrics","items":[{"label":"Requests / min","value":1240,"delta":"+8% vs last hour","tone":"good","trend":[880,920,1010,990,1100,1180,1240]},{"label":"p95 latency","value":"182","unit":"ms","delta":"+40 ms","tone":"warn","trend":[120,130,128,150,160,175,182]}]}
```

```hermes-ui
{"v":1,"type":"services","title":"Services","items":[{"name":"Jellyfin","state":"up","latency":38,"sub":"Workbench"},{"name":"Seerr","state":"degraded","latency":"910 ms","sub":"Pathfinder","ask":"Restart Seerr?"},{"name":"AdGuard Home","state":"up","latency":4},{"name":"Backups","state":"down","sub":"NAS-01 · last run failed"}]}
```

```hermes-ui
{"v":1,"type":"alerts","items":[{"tone":"bad","title":"/srv is 91% full","body":"About 4 days left at the current rate.","time":"12 min ago","actions":[{"label":"Find big files","send":"Which folders on /srv are the biggest?"}]},{"tone":"warn","title":"Seerr responds slowly","time":"1 h ago","actions":[{"label":"Restart Seerr?","send":"Restart Seerr."}]}]}
```

```hermes-ui
{"v":1,"type":"chart","kind":"line","title":"CPU, last 12 hours","unit":"%","labels":["00:00","02:00","04:00","06:00","08:00","10:00","12:00"],"series":[{"name":"Pathfinder","values":[12,10,9,14,31,27,23]},{"name":"Workbench","values":[40,35,22,18,44,52,48]}]}
```
''';

const companyHtml =
    '''<section style="display:flex;gap:14px;align-items:center">
  <img src="https://img.example.com/logo.png" alt="NVIDIA logo" style="width:52px;height:52px;border-radius:12px">
  <div>
    <h3>NVIDIA Corporation</h3>
    <small>Semiconductors · Santa Clara, California</small>
  </div>
</section>
<div style="display:grid;grid-template-columns:repeat(2,1fr);gap:12px">
  <figure><img src="https://img.example.com/gpu.jpg" alt="Data-centre GPU"><figcaption>Data-centre accelerator</figcaption></figure>
  <figure><img src="https://img.example.com/campus.jpg" alt="Headquarters"><figcaption>Headquarters, Santa Clara</figcaption></figure>
</div>
<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;background:#76b900;color:#fff">
  <div><small>Founded</small><p><strong>1993</strong></p></div>
  <div><small>CEO</small><p><strong>Jensen Huang</strong></p></div>
  <div><small>Known for</small><p><strong>GPUs, CUDA</strong></p></div>
</div>
<h4>Main businesses</h4>
<ul>
  <li><strong>Data centre:</strong> accelerators and networking for AI training and inference.</li>
  <li><strong>Gaming:</strong> GeForce graphics cards and laptops.</li>
  <li><strong>Automotive and robotics:</strong> DRIVE and Jetson platforms.</li>
</ul>
<table>
  <thead><tr><th>Segment</th><th>Share of revenue</th></tr></thead>
  <tbody><tr><td>Data centre</td><td>Most</td></tr><tr><td>Gaming</td><td>Smaller</td></tr></tbody>
</table>
<p>More on the <a href="https://example.com/investors" onclick="steal()">investor site</a>.</p>
<script>alert(1)</script>''';

const companyReply =
    '''NVIDIA designs the chips behind most AI training today.

```hermes-html
$companyHtml
```
''';

/// Prose, a dashboard block and HTML in one reply.
const mixedReply = '''# Weekend media check

<small>Saturday · checked 2 minutes ago</small>

Your media stack is healthy. Two downloads are queued and the library grew by 14 titles this week.

```hermes-ui
{"v":1,"type":"services","items":[{"name":"Jellyfin","state":"up","latency":41},{"name":"Sonarr","state":"up","latency":22},{"name":"qBittorrent","state":"degraded","latency":"640 ms","ask":"Why is qBittorrent slow?"}]}
```

```hermes-html
<div style="display:grid;grid-template-columns:repeat(2,1fr);gap:12px">
  <div><small>New this week</small><p><strong>14 titles</strong></p></div>
  <div><small>Queued</small><p><strong>2 downloads</strong></p></div>
</div>
<p>Library scan: <span style="color:#16a34a">healthy</span> · Disk: <span style="color:#d97706">78% full</span> · Last error: <span style="color:rgb(220,38,38)">none today</span></p>
<p><strong>Tip:</strong> the queue clears faster overnight, when the <em>bandwidth limit</em> is off.</p>
```

```hermes-ui
{"v":1,"type":"chart","kind":"bar","title":"Titles added","labels":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"series":[{"name":"Added","values":[1,3,0,2,4,3,1]}]}
```

**Next step:** nothing needed today.
''';
