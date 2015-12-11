.PHONY: all binary ut clean run-service-proxy run-kubernetes-master

SRCFILES=$(shell find calico_kubernetes)
LOCAL_IP_ENV?=$(shell ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
K8S_VERSION=1.1.2

default: all
all: binary test
test: ut
binary: dist/calico

dist/calico: $(SRCFILES)
	mkdir -p dist
	chmod 777 `pwd`/dist

	# Stop the master kubelet since if it's running it holds a lock on the file
	-docker stop calico-kubelet-master
	# Build the kubernetes plugin
	docker pull calico/build:latest
	docker run \
	-u user \
	-v `pwd`/dist:/code/dist \
	-v `pwd`/calico_kubernetes:/code/calico_kubernetes \
	calico/build pyinstaller calico_kubernetes/calico_kubernetes.py -n calico -a -F -s --clean

ut:
	docker run --rm -v `pwd`/calico_kubernetes:/code/calico_kubernetes \
	-v `pwd`/calico_kubernetes/nose.cfg:/code/nose.cfg \
	calico/test \
	nosetests calico_kubernetes/tests -c nose.cfg

# UT runs on Cicle
ut-circle: binary
	# Can't use --rm on circle
	# Circle also requires extra options for reporting.
	docker run \
	-v `pwd`:/code \
	-v $(CIRCLE_TEST_REPORTS):/circle_output \
	-e COVERALLS_REPO_TOKEN=$(COVERALLS_REPO_TOKEN) \
	calico/test sh -c \
	'	nosetests calico_kubernetes/tests -c nose.cfg \
	--with-xunit --xunit-file=/circle_output/output.xml; RC=$$?;\
	[[ ! -z "$$COVERALLS_REPO_TOKEN" ]] && coveralls || true; exit $$RC'

dist/calicoctl:
	mkdir -p dist
	curl -L http://www.projectcalico.org/builds/calicoctl -o dist/calicoctl
	chmod +x dist/calicoctl

#run-kubernetes-master: stop-kubernetes-master run-etcd run-service-proxy binary
run-kubernetes-master: stop-kubernetes-master run-etcd binary
	# Run the kubelet which will launch the master components in a pod.
	docker run \
	--name calico-kubelet-master \
	--volume=`pwd`/dist:/usr/libexec/kubernetes/kubelet-plugins/net/exec/calico:ro \
	--volume=/:/rootfs:ro \
	--volume=/sys:/sys:ro \
	--volume=/var/lib/docker/:/var/lib/docker:rw \
	--volume=/var/lib/kubelet/:/var/lib/kubelet:rw \
	--volume=/var/run:/var/run:rw \
	--net=host \
	--pid=host \
	--privileged=true \
	-e KUBE_API_ROOT=http://$(LOCAL_IP_ENV):8080/api/v1/ \
	-d \
	gcr.io/google_containers/hyperkube:v$(K8S_VERSION) \
	/hyperkube kubelet --network-plugin calico --v=5 --containerized  --register-node=false --hostname-override="master" --address="0.0.0.0" --api-servers=http://localhost:8080 --config=/etc/kubernetes/manifests-multi

#	# Start the calico node
#	sudo dist/calicoctl node

stop-kubernetes-master:
	# Stop any existing kubelet that we started
	-docker rm -f calico-kubelet-master

	# Remove any pods that the old kubelet may have started.
	-docker rm -f $$(docker ps | grep k8s_ | awk '{print $$1}')


#HOSTS=calico-01 calico-02
HOSTS=calico-01
ted:
	for NAME in $(HOSTS) ; do \
		echo $$NAME ; \
	done

run-kubernetes-nodes: kubelet docker dist/calicoctl calico-node.tar binary
#	@ID=$$(docker run --privileged -v `pwd`:/code -v `pwd`/docker:/usr/local/bin/docker \
#	-tid calico/dind:latest) ;\


	# Run the dind containers
	for NAME in $(HOSTS) ; do \
		mkdir -p logs/$$NAME ;\
		chmod +w logs/$$NAME ;\
	  docker rm -f $$NAME ; \
    docker run --name $$NAME -h $$NAME --privileged \
    -v `pwd`:/code \
    -v `pwd`/docker:/usr/local/bin/docker \
    -v `pwd`/dist:/usr/libexec/kubernetes/kubelet-plugins/net/exec/calico:ro \
    -tid calico/dind:latest ;\
    docker exec -tid $$NAME /code/kubelet --network-plugin calico --logtostderr=false --log-dir=/code/logs/$$NAME --api-servers=http://${LOCAL_IP_ENV}:8080 --v=2 --address=0.0.0.0 --enable-server --cluster-dns=10.0.0.10 --cluster-domain=cluster.local ; \
		docker exec -ti $$NAME docker load --input /code/calico-node.tar ; \
		docker exec -ti $$NAME sh -c "ETCD_AUTHORITY=${LOCAL_IP_ENV}:2379 /code/dist/calicoctl node" ;\
	done


#    dist/calicoctl node

# docker daemon --storage-driver=aufs

#		$$TARGET docker load --input /code/busybox.tar ; \
#		$$TARGET docker load --input /code/calico-node.tar ; \
#		$$TARGET ln -s /code/calicoctl /usr/local/bin ; \
#	done
#
#	# Start the calico node
#	sudo dist/calicoctl node

run-kube-proxy:
	-docker rm -f calico-kube-proxy
	docker run --name calico-kube-proxy -d --net=host --privileged gcr.io/google_containers/hyperkube:v$(K8S_VERSION) /hyperkube proxy --master=http://127.0.0.1:8080 --v=2

## Download kube* files (such as kubectl and kubelet)
kube%:
	wget http://storage.googleapis.com/kubernetes-release/release/v$(K8S_VERSION)/bin/linux/amd64/$@
	chmod 755 $@

calico-node.tar:
	docker pull calico/node:latest
	docker save --output calico-node.tar calico/node:latest

## Run etcd in a container. Used by the STs and generally useful.
run-etcd:
	@-docker rm -f calico-etcd
	docker run --detach \
	--net=host \
	--name calico-etcd quay.io/coreos/etcd:v2.2.2 \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

## Download the latest docker binary
docker:
	curl https://get.docker.com/builds/Linux/x86_64/docker-1.9.0 -o docker
	chmod +x docker

clean:
	find . -name '*.pyc' -exec rm -f {} +
	-rm kubectl
	-rm -rf dist
	-docker run -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker:/var/lib/docker --rm martin/docker-cleanup-volumes

