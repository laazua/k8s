### k8s

- **说明**
1. k8s集群高可用部署
2. k8s相关技术栈知识

- **部署**
1. ansible主控节点与k8s集群节点做好ssh免密登录且免密用户有提权执行命令的权限(ansible主控免密:cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys).
2. ansible主控节点需要安装的工具cfssl和cfssljson用于证书签名.
3. 使用deploy下的ansible脚本部署: ansible-playbook k8s.yml.
4. 也可使用ansible-playbook的--tags或者--skip-tags参数指定部署的模块或者要跳过的模块,具体可用的tag关注各个role中的task任务中的tag字段.
5. 在安装前，需要修改ansible配置文件中的hosts文件，添加k8s集群节点信息，以及group_vars路径中k8s集群的相关配置信息(主要注意:etcd_hosts和api_hosts).
6. 如果在下载相关组件包遇到网络问题，可以先将包下载到本地的deploy/tgzfile目录下, 然后再进行部署.
7. 我部署的系统是debian12, 其他系统该脚本需要进行适当修改方可使用.

- **etcd集群状态查看**
1. sudo etcdctl --endpoints=https://192.168.165.80:2379,https://192.168.165.81:2379,https://192.168.165.82:2379 --cert=/etc/kubernetes/pki/etcd/etcd.pem --key=/etc/kubernetes/pki/etcd/etcd-key.pem --cacert=/etc/kubernetes/pki/etcd/etcd-ca.pem endpoint health
2. sudo etcdctl --endpoints=https://192.168.165.80:2379,https://192.168.165.81:2379,https://192.168.165.82:2379 --cert=/etc/kubernetes/pki/etcd/etcd.pem --key=/etc/kubernetes/pki/etcd/etcd-key.pem --cacert=/etc/kubernetes/pki/etcd/etcd-ca.pem endpoint status --write-out=table


- **设置集群节点角色**
1. kubectl label nodes node-00 node-role.kubernetes.io/master=""
2. kubectl label nodes node-01 node-role.kubernetes.io/master=""
3. kubectl label nodes node-02 node-role.kubernetes.io/master=""
4. kubectl label nodes node-03 node-role.kubernetes.io/worker=""
5. kubectl label nodes node-04 node-role.kubernetes.io/worker=""

- **安装网络插件**
1. calico
2. flannel
3. cilium(推荐)  
   > a. helm repo add cilium https://helm.cilium.io  
   > b. helm pull cilium/cilium  
   > c. helm install cilium cilium/cilium -n kube-system  
   > d. [具体参考](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/#gs-gateway-api)
