#!/usr/bin/env bash

#parameter for cleanup ami, in seconds (1 day=86400s; 1 week=604800s;)
declare -i Max_Age=604800
HTTP_PORT=80
NC_PORT=80
#HTTP_URL_Part="/csp/ibs/mdm.Index.cls"
HTTP_URL_Part="/server-status"
TAG_VALUE="NI_"

echo " "
echo " 0. Query from AWS ======================================================================="
echo " "
aws  ec2 describe-instances --output=text --query 'Reservations[*].Instances[*].[InstanceId,PublicDnsName,State.Name,[Tags[?Key==`Name`].Value]]'
echo " "

AwsOwnerID=$(aws ec2 describe-security-groups --query 'SecurityGroups[0].OwnerId' --output text)
echo "    Owner ID: " ${AwsOwnerID}
mapfile  aws_inst_id < <( aws ec2 describe-instances --output=text --filters 'Name=tag:Name,Values='${TAG_VALUE}* --query 'Reservations[*].Instances[*].[InstanceId]' )

echo " "
echo " 1. Checking instanses status ============================================================="
echo " "

declare -i i=0
for a_id in ${aws_inst_id[@]};
    do echo "Item:            " ${i}
       aws_inst_state[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[State.Name]')
       aws_inst_pdns[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[PublicDnsName]')
       aws_inst_name[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value]')
       echo "Instance ID:     " ${aws_inst_id[${i}]}
       echo "InstanseTagName: " ${aws_inst_name[${i}]}
       echo "Instance State:  " ${aws_inst_state[${i}]}

       if [ -n "${aws_inst_pdns[${i}]}" ]; then
             echo "curl output: "
             curl -I -L --connect-timeout 3 --max-time 10 ${aws_inst_pdns[${i}]}:${HTTP_PORT}${HTTP_URL_Part} 2>&1
             aws_http_err[${i}]=$?;
             echo -en "curl http check result "
             if (( $((${aws_http_err[${i}]})) == 0  ));
                then echo -en "\033[1;32m === OK === \033[1;00m\n";
                else echo -en "\033[1;31m Error code: "${aws_http_err[${i}]} "\033[1;00m\n";
             fi

             echo " nc  output:"
             nc -zv -w 3 ${aws_inst_pdns[${i}]} ${NC_PORT} 2>&1
             aws_tcp_err[${i}]=$?;

             echo -en " nc  tcp  check result "
             if (( $((${aws_tcp_err[${i}]})) == 0  ));
                then echo -en "\033[1;32m === OK === \033[1;00m\n";
                else echo -en "\033[1;31m Error code: "${aws_tcp_err[${i}]} "\033[1;00m\n";
             fi;

         else
            echo -en "\033[1;33m Unable to perform http\tcp checks\033[1;00m\n";
       fi
       echo "--------------------------------------------"
       i+=1
done

echo " "
echo " 2,3 Creating ami image then terminate instance  =========================================="
echo " "
declare -i i=0
for a_id in ${aws_inst_id[@]};
    do
       if [[ "${aws_inst_state[${i}]}" =~ .*stopped.* ]]; then
            echo -en "Creating Ami of " ${aws_inst_id[${i}]} " instance "
            ImageId=$(aws ec2 create-image --instance-id  ${aws_inst_id[${i}]} --name ${aws_inst_name[${i}]}_$(date +%Y%m%d-%H%M%S) |  grep ImageId | cut -d':' -f2 | cut -d'"' -f2 )
            while [[ "$(aws ec2 describe-images --image-ids ${ImageId} --query 'Images[*].{STATE:State}' | grep STATE | cut -d':' -f2 | cut -d'"' -f2)" =~ .*pending.* ]]
               do
                   sleep 5s;echo -en "."
             done
            echo -en " Created Ami " ${ImageId}
            aws ec2 create-tags  --resources ${ImageId} --tags Key=Name,Value=${aws_inst_name[${i}]}_$(date +%Y%m%d-%H%M%S)
            echo " Ami tagged "
            echo $( aws ec2 terminate-instances --instance-ids ${aws_inst_id[${i}]} )
       fi
    i+=1
done


echo " "
echo " 4. Deregistering old images =============================================================="
echo " "
#mapfile  aws_img_id < <( aws ec2 describe-images --owners ${AwsOwnerID}  --query 'Images[*].[ImageId]' --output=text )
mapfile  aws_img_id < <( aws ec2 describe-images --owners ${AwsOwnerID} --filters 'Name=tag:Name,Values='${TAG_VALUE}* --query 'Images[*].[ImageId]' --output=text )

declare -i i=0
for a_id in ${aws_img_id[@]};
    do
       Img_Age=$(( $(date +%s ) -  $(date -d $( aws ec2 describe-images --image-ids  ${aws_img_id[${i}]}  --owners ${AwsOwnerID} --query 'Images[*].[CreationDate]' --output=text )  +%s)  ))
       echo -en "\nImage: " ${aws_img_id[${i}]}  "  Age: " ${Img_Age}
       if (( $((Img_Age)) >  $((Max_Age)) ));
#       if (( $((Img_Age)) <  $((Max_Age)) )) && (( $((Img_Age)) > 600  ))  ;
          then echo -en "\t\033[1;31mDeleting\033[1;00m " ${aws_img_id[${i}]}
               aws ec2 deregister-image --image-id ${aws_img_id[${i}]}
          else echo -en "\t\033[1;36mSkipping\033[1;00m " ${aws_img_id[${i}]}
       fi
    i+=1
done


echo " "
echo " 5. Print instanses state ================================================================="
echo " "
declare -i i=0
for a_id in ${aws_inst_id[@]};
    do aws_inst_state[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[State.Name]')
       aws_inst_pdns[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[PublicDnsName]')
       aws_inst_name[${i}]=$(aws ec2 describe-instances --instance-id ${a_id} --output=text --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value]')
       echo "Item:            " ${i}
       echo "Instance ID:     " ${aws_inst_id[${i}]}
       echo "InstanseTagName: " ${aws_inst_name[${i}]}
       if [[ "${aws_inst_state[${i}]}" =~ .*running.* ]]
          then echo -en "Instance State:  \033[1;32m running       \033[1;00m\n"
       elif [[ "${aws_inst_state[${i}]}" =~ .*pending.* ]]
          then echo -en "Instance State:  \033[1;33m pending       \033[1;00m\n"
       elif [[ "${aws_inst_state[${i}]}" =~ .*shutting-down.* ]]
          then echo -en "Instance State:  \033[1;31m shutting-down \033[1;00m\n"
       elif [[ "${aws_inst_state[${i}]}" =~ .*terminated.* ]]
          then echo -en "Instance State:  \033[1;35m terminated    \033[1;00m\n"
       elif [[ "${aws_inst_state[${i}]}" =~ .*stopping.* ]]
          then echo -en "Instance State:  \033[1;33m stopping      \033[1;00m\n"
       elif [[ "${aws_inst_state[${i}]}" =~ .*stopped.* ]]
          then echo -en "Instance State:  \033[1;31m stopped       \033[1;00m\n"
       else    echo -en "Instance State:  \033[1;38m unknown       \033[1;00m\n"
       fi
       echo " ------------------------------------------------------------------------------------------"
    i+=1
done
echo " Done. ===================================================================================="

