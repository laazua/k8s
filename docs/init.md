## 项目初始化

项目目标:
  - 二进制的形式部署k8s集群的脚本
  - 通用部署：
    1. 通过配置可以部署任意版本的k8s集群
    2. 可以在任意发行版本的linux主机上进行部署
  - 后续可通过该项目脚本对集群进行版本升级

实现要求:
  - 用 ansible 部署k8s集群(二进制部署)
  - 项目结构用 ansible role 的形式
  - CRI: containerd
  - CNI: Cilium
  - 集群的master节点采用高可用的方式进行部署
  - 后续所有的应用都只能限制部署在node节点上
  - 后续可以方便往集群中添加新的节点
  - 使用tdd开发模式(测试驱动开发)
  - 部署过程中，如果下载二进制包或者依赖网络不同，可以进行代理设置

harness系统：
  1. 根据上面的项目目标和实现要求给出一套 AI agent 驱动开发的harness系统,要求给出完整的harness系统可以直接使用.
  2. 给出具体如何通过上下文对harness系统进行驱动
  3. 参考官方：https://www.anthropic.com/engineering/harness-design-long-running-apps
  4. harness放置位置docs/harness/
  5. AGENTS.md作为驱动harness的唯一入口(AI Agent项目地图)
  6. 实现的harness系统驱动开发过程中要尽量节约token
