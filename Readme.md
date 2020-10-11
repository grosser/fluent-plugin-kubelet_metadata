# Fluent Plugin Kubelet Metadata

- adds log metadata from kubelet
- faster than kubernetes api + does not risk taking down the api
- includes throttling (10 QPS)
- includes LRU cache (200 slots)
- metrics to report and debug problem pods
- Simpler/faster/less memory than [fluent-plugin-kubernetes_metadata_filter](https://github.com/fabric8io/fluent-plugin-kubernetes_metadata_filter)

Install
=======

```Bash
gem install fluent-plugin-kubelet_metadata
```

Output
======

```json
{
  "log": "2015/05/05 19:54:41 \n",
  "stream": "stderr",
  "docker": {
    "id": "df14e0d5ae4c07284fa636d739c8fc2e6b52bc344658de7d3f08c36a2e804115"
  },
  "kubernetes": {
    "pod_name":"my-app-98rqc",
    "container_name": "main",
    "namespace_name": "my-namespace",
    "labels": {
      "app": "my-app"
    }
  }
}
```

Usage
=====

```
<source>
  @type tail
  path /var/log/containers/*.log
  pos_file fluentd-docker.pos
  read_from_head true
  tag kubernetes.*
  <parse>
    <pattern>
      format json
      time_key time
      time_type string
      time_format "%Y-%m-%dT%H:%M:%S.%NZ"
      keep_time_key false
    </pattern>
  </parse>
</source>

<filter kubernetes.var.log.containers.**.log>
  @type kubelet_metadata
</filter>

<match **>
  @type stdout
  # statsd StatsdDelegator # optional, where to send stats via `.increment` calls (top level class names only)
</match>
```

TODO
====

- metrics should be easier to access
- make more settings configurable
- settings for more metadata like pod uid or hostname / ip
- detect `--dry-run` without using `ARGV`
- Verify ssl when calling kubelet, by using cert and hostname like
  `curl https://ip-172-16-114-118.us-west-2.compute.internal:10250/pods --cacert /srv/kubernetes/kubelet-ca.crt`
- Cache hard-misses for a few seconds to avoid doing useless requests (pods don't get added after logs were found)
  LRU cache does not support dynamic TTL, so we'd have to store value and expire time
  this is tricky since there is a race condition between storing a `miss` and filling the cache at the same time
  so we need to split "getting pods" from "storing results" and put that and "miss" logic in a mutex
- Store metadata whenever a pod starts (like watch api) so even short-running pods can have their logs routed reliably.
  Ideally persist metadata to host disk so restarting fluentd does not lose logs of pods that are gone.
  Metadata service with memory could also work, but it would need to persist data across restarts.

Author
======
[Michael Grosser](http://grosser.it)<br/>
michael@grosser.it<br/>
License: MIT<br/>
[![Build Status](https://travis-ci.org/grosser/fluent-plugin-kubelet_metadata_filter.svg)](https://travis-ci.org/grosser/fluent-plugin-kubelet_metadata_filter)
[![coverage](https://img.shields.io/badge/coverage-100%25-success.svg)](https://github.com/grosser/single_cov)
