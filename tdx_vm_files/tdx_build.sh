# Builds component for tdx

cd /home/ubuntu/mnt/

echo "Running TDX VM setup script"

echo "Building cvmrdma-rdma-core"

cd cvmrdma-rdma-core
echo "pwd: $(pwd)"
bash build.sh


echo "Done building cvmrdma-rdma-core"
echo "------------------------------"
echo "Building cvmrdma-manager"


cd ../cvmrdma-manager
echo "pwd: $(pwd)"
make

echo "Done building cvmrdma-manager"
echo "------------------------------"
exit 0