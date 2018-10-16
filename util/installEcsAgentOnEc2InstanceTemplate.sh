sudo yum update -y
sudo mkdir /etc/ecs
sudo touch /etc/ecs/ecs.config
echo "ECS_CLUSTER=$CLUSTER_NAME" >> /etc/ecs/ecs.config
sudo yum install -y ecs-init
sudo service docker start
sudo start ecs
