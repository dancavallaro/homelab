In-progress (updated 3/15/26):
* Working on shopping list app (https://docs.google.com/document/d/1LTH-zNL13lZQ71D6qiNLJBcUhEnh0u1DU0Vdz9xBK98/edit?usp=sharing)
  * React Expo version at /Users/dan/workspace/shopping-list, working-ish but looks crappy
  * SwiftUI version at /Users/dan/workspace/xcode/ShoppingList, Claude-generated but not building yet

TODOs:
* Submit kubectl-unmount to Krew index (need to rename first)
* Storage/NAS:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Those transient Volsync PVs should (probably?) be on local-path instead of iSCSI
* When on UPS power w/o Internet, Pocket-ID breaks because DNS is broken (ArgoCD for example)
* Fix Stults/Terhune parsers to properly handle text updates
* Test restoring a brand new cluster from a cluster etcd backup
* Set up an IPv6-only test cluster
