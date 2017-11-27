#! /bin/bash
# aws ec2 run-instances --count 2 --image-id ami-2fb42b39 --instance-type t2.large --key-name libra --subnet-id subnet-cf57c596 --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=jcope-test}]' 'ResourceType=volume,Tags=[{Key=Name,Value=jcope-test}]'

function aws::create-instances() {
	
}
