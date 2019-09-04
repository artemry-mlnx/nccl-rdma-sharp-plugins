#!/bin/bash -l

SCRIPT_DIR="$( cd "$(dirname "$0")" ; pwd -P )"
. ${SCRIPT_DIR}/settings.sh

# Available values: start|stop|restart
SHARP_MANAGER_ACTION="${1:-restart}"
echo "INFO: SHARP_MANAGER_ACTION = ${SHARP_MANAGER_ACTION}"

CFG_DIR="${SCRIPT_DIR}/cfg"
HOSTFILE="${CFG_DIR}/$HOSTNAME/hostfile"
export SHARP_CONF="${CFG_DIR}/$HOSTNAME/sharp_conf/"
export SHARP_INI_FILE="/tmp/sharp_manager_$$.ini"

if [ ! -d "${SHARP_CONF}" ]
then
    echo "ERROR: SHARP_CONF (${SHARP_CONF}) does not exist or not accessible"
    echo "FAIL"
    exit 1
fi

if [ -f "${SHARP_INI_FILE}" ]
then
    echo "ERROR: SHARP_INI_FILE (${SHARP_INI_FILE}) does not exist or not accessible"
    echo "FAIL"
    exit 1
fi

if [ ! -f "${HOSTFILE}" ]
then
    echo "ERROR: ${HOSTFILE} doesn't exist or not accessible"
    echo "FAIL"
    exit 1
fi

if [ -f "${SHARP_CONF}/sharp_am_node.txt" ]
then
    SHARP_AM_NODE=`cat ${SHARP_CONF}/sharp_am_node.txt`
    echo "INFO: SHARP_AM_NODE = ${SHARP_AM_NODE}"
else
    echo "ERROR: ${SHARP_CONF}/sharp_am_node.txt does not exist or not accessible"
    echo "FAIL"
    exit 1
fi

IB_DEV="mlx5_0"
SM_GUID=`sudo sminfo -C ${IB_DEV} -P1 | awk '{print $7}' | cut -d',' -f1`
# SM/AM node
# SM_HOSTNAME=`sudo ibnetdiscover -H -C mlx5_0 -P1  | grep ${SM_GUID} | awk -F'"' '{print $2 }' | awk '{print $1}'`
HOSTS=`cat $HOSTFILE | xargs | tr ' ' ','`

echo "INFO: HOSTFILE = ${HOSTFILE}"
echo "INFO: IB_DEV = ${IB_DEV}"
echo "INFO: SM_GUID = ${SM_GUID}"
# echo "INFO: SM_HOSTNAME = ${SM_HOSTNAME}"
echo "INFO: HOSTS = ${HOSTS}"

rm -f ${SHARP_INI_FILE}

cat > ${SHARP_INI_FILE} <<EOF
sharp_AM_server="${SHARP_AM_NODE}"
sharp_am_log_verbosity="3"
sharp_hostlist="$HOSTS"
sharp_manager_general_conf="${SHARP_CONF}"
sharpd_log_verbosity="3"
EOF

echo "INFO: SHARP_INI_FILE ${SHARP_INI_FILE} BEGIN"
cat ${SHARP_INI_FILE}
echo "INFO: SHARP_INI_FILE ${SHARP_INI_FILE} END"

check_opensm_status() {
    echo "Checking OpenSM status on ${SHARP_AM_NODE}..."

    ssh "${SHARP_AM_NODE}" "systemctl status opensmd"
    if [ $? -ne 0 ]
    then
        echo "ERROR: opensmd is not run on ${SHARP_AM_NODE}"
        echo "FAIL"
        exit 1
    fi

    echo "Checking OpenSM status on ${SHARP_AM_NODE}... DONE"
}

check_opensm_conf() {
    echo "INFO: check_opensm_conf on ${SHARP_AM_NODE}..."

    OPENSM_CONFIG="/etc/opensm/opensm.conf"
    echo "INFO: opensm config = ${OPENSM_CONFIG}"

    ssh "${SHARP_AM_NODE}" "grep \"routing_engine.*updn\" ${OPENSM_CONFIG} 2>/dev/null"
    if [ $? -ne 0 ]
    then
        echo "ERROR: wrong value of routing_engine parameter in ${OPENSM_CONFIG}"
        echo "Should be (example): routing_engine updn"
        echo "FAIL"
        exit 1
    fi

    ssh "${SHARP_AM_NODE}" "grep \"sharp_enabled.*2\" ${OPENSM_CONFIG} 2>/dev/null"
    if [ $? -ne 0 ]
    then
        echo "ERROR: wrong value of sharp_enabled parameter in ${OPENSM_CONFIG}"
        echo "Should be (example): sharp_enabled 2"
        echo "FAIL"
        exit 1
    fi

    echo "INFO: check_opensm_conf on ${SHARP_AM_NODE}... DONE"
}

verify_sharp() {
    echo "INFO: verify_sharp..."

    export PATH="${SHARP_DIR}/bin:$PATH"
    export LD_LIBRARY_PATH="${SHARP_DIR}/lib:${LD_LIBRARY_PATH}"

    TMP_DIR="`pwd`/verify_sharp_$$"
    mkdir -p ${TMP_DIR}
    cp ${SHARP_DIR}/share/sharp/examples/mpi/coll/* ${TMP_DIR}
    cd ${TMP_DIR}
    make CUDA=1 CUDA_HOME=${CUDA_HOME} SHARP_HOME="${SHARP_DIR}"
    if [ $? -ne 0 ]
    then
        echo "ERROR: verify_sharp make failed"
        echo "FAIL"
        exit 1
    fi

    ITERS=100
    SKIP=20

    # Test 1 (from ${SHARP_DIR}/share/sharp/examples/mpi/coll/README):
    # Run allreduce barrier perf test on 2 hosts using port mlx5_0
    echo "Test 1..."
    mpirun \
        -np 2 \
        -H $HOSTS \
        --map-by node \
        -x ENABLE_SHARP_COLL=1 \
        -x SHARP_COLL_LOG_LEVEL=3 \
        -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH} \
        ${TMP_DIR}/sharp_coll_test \
            -d mlx5_0:1 \
            --iters $ITERS \
            --skip $SKIP \
            --mode perf \
            --collectives allreduce,barrier
    if [ $? -ne 0 ]
    then
        echo "ERROR: verify_sharp Test 1 failed"
        echo "FAIL"
        exit 1
    fi
    echo "Test 1... DONE"

    # Test 2 (from ${SHARP_DIR}/share/sharp/examples/mpi/coll/README):
    # Run allreduce perf test on 2 hosts using port mlx5_0 with CUDA buffers
    echo "Test 2..."
    mpirun \
        -np 2 \
        -H $HOSTS \
        --map-by node \
        -x ENABLE_SHARP_COLL=1 \
        -x SHARP_COLL_LOG_LEVEL=3 \
        -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH} \
        ${TMP_DIR}/sharp_coll_test \
            -d mlx5_0:1 \
            --iters $ITERS \
            --skip $SKIP \
            --mode perf \
            --collectives allreduce \
            -M cuda
    if [ $? -ne 0 ]
    then
        echo "ERROR: verify_sharp Test 2 failed"
        echo "FAIL"
        exit 1
    fi
    echo "Test 2... DONE"

    # Test 3 (from ${SHARP_DIR}/share/sharp/examples/mpi/coll/README):
    # Run allreduce perf test on 2 hosts using port mlx5_0 with Streaming aggregation from 4B to 512MB
    echo "Test 3..."
    mpirun \
        -np 2 \
        -H $HOSTS \
        --map-by node \
        -x ENABLE_SHARP_COLL=1 \
        -x SHARP_COLL_LOG_LEVEL=3 \
        -x SHARP_COLL_ENABLE_SAT=1 \
        -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH} \
        ${TMP_DIR}/sharp_coll_test \
            -d mlx5_0:1 \
            --iters $ITERS \
            --skip $SKIP \
            --mode perf \
            --collectives allreduce \
            -s 4:536870912
    if [ $? -ne 0 ]
    then
        echo "ERROR: verify_sharp Test 3 failed"
        echo "FAIL"
        exit 1
    fi
    echo "Test 3... DONE"

    cd - > /dev/null
    rm -rf ${TMP_DIR}

    # Test 4: Without SAT
    echo "Test 4..."
    $OMPI_HOME/bin/mpirun \
        --bind-to core \
        --map-by node \
        -host $HOSTS \
        -np 2 \
        -mca btl_openib_warn_default_gid_prefix 0 \
        -mca rmaps_dist_device mlx5_0:1 \
        -mca rmaps_base_mapping_policy dist:span \
        -x MXM_RDMA_PORTS=mlx5_0:1 \
        -x HCOLL_MAIN_IB=mlx5_0:1 \
        -x MXM_ASYNC_INTERVAL=1800s \
        -x MXM_LOG_LEVEL=ERROR \
        -x HCOLL_ML_DISABLE_REDUCE=1 \
        -x HCOLL_ENABLE_MCAST_ALL=1 \
        -x HCOLL_MCAST_NP=1 \
        -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${SHARP_DIR}/lib \
        -x LD_PRELOAD=${SHARP_DIR}/lib/libsharp.so:${SHARP_DIR}/lib/libsharp_coll.so \
        -x HCOLL_ENABLE_SHARP=2 \
        -x SHARP_COLL_LOG_LEVEL=3 \
        -x SHARP_COLL_GROUP_RESOURCE_POLICY=1 \
        -x SHARP_COLL_MAX_PAYLOAD_SIZE=256 \
        -x HCOLL_SHARP_UPROGRESS_NUM_POLLS=999 \
        -x HCOLL_BCOL_P2P_ALLREDUCE_SHARP_MAX=4096 \
        -x SHARP_COLL_PIPELINE_DEPTH=32 \
        -x SHARP_COLL_JOB_QUOTA_OSTS=32 \
        -x SHARP_COLL_JOB_QUOTA_MAX_GROUPS=4 \
        -x SHARP_COLL_JOB_QUOTA_PAYLOAD_PER_OST=256 \
        taskset -c 1 \
            numactl --membind=0 \
                $OMPI_HOME/tests/osu-micro-benchmarks-5.3.2/osu_allreduce \
                    -i 100 \
                    -x 100 \
                    -f \
                    -m 4096:4096
    if [ $? -ne 0 ]
    then
        echo "ERROR: Test 4 (without SAT) failed, check the log file"
        echo "FAIL"
        exit 1
    fi
    echo "Test 4... DONE"

    # Test 5: With SAT
    echo "Test 5..."
    $OMPI_HOME/bin/mpirun \
        --bind-to core \
        --map-by node \
        -host $HOSTS \
        -np 2 \
        -mca btl_openib_warn_default_gid_prefix 0 \
        -mca rmaps_dist_device mlx5_0:1 \
        -mca rmaps_base_mapping_policy dist:span \
        -x MXM_RDMA_PORTS=mlx5_0:1 \
        -x HCOLL_MAIN_IB=mlx5_0:1 \
        -x MXM_ASYNC_INTERVAL=1800s \
        -x MXM_LOG_LEVEL=ERROR \
        -x HCOLL_ML_DISABLE_REDUCE=1 \
        -x HCOLL_ENABLE_MCAST_ALL=1 \
        -x HCOLL_MCAST_NP=1 \
        -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${SHARP_DIR}/lib \
        -x LD_PRELOAD=${SHARP_DIR}/lib/libsharp.so:${SHARP_DIR}/lib/libsharp_coll.so \
        -x HCOLL_ENABLE_SHARP=2 \
        -x SHARP_COLL_LOG_LEVEL=3 \
        -x SHARP_COLL_GROUP_RESOURCE_POLICY=1 \
        -x SHARP_COLL_MAX_PAYLOAD_SIZE=256 \
        -x HCOLL_SHARP_UPROGRESS_NUM_POLLS=999 \
        -x HCOLL_BCOL_P2P_ALLREDUCE_SHARP_MAX=4096 \
        -x SHARP_COLL_PIPELINE_DEPTH=32 \
        -x SHARP_COLL_JOB_QUOTA_OSTS=32 \
        -x SHARP_COLL_JOB_QUOTA_MAX_GROUPS=4 \
        -x SHARP_COLL_JOB_QUOTA_PAYLOAD_PER_OST=256 \
        -x SHARP_COLL_ENABLE_SAT=1 \
        taskset -c 1 \
            numactl --membind=0 \
                $OMPI_HOME/tests/osu-micro-benchmarks-5.3.2/osu_allreduce \
                    -i 100 \
                    -x 100 \
                    -f \
                -m 4096:4096
    if [ $? -ne 0 ]
    then
        echo "ERROR: Test 5 (with SAT) failed, check the log file"
        echo "FAIL"
        exit 1
    fi
    echo "Test 5... DONE"

    echo "INFO: verify_sharp... DONE"
}

if [ "${SHARP_MANAGER_ACTION}" != "stop" ]
then
    check_opensm_status
    check_opensm_conf
fi

sudo PDSH_RCMD_TYPE=ssh SHARP_INI_FILE=${SHARP_INI_FILE} SHARP_CONF=${SHARP_CONF} ${SHARP_DIR}/sbin/sharp_manager.sh "${SHARP_MANAGER_ACTION}" -l "$HOSTS" -s "${SHARP_AM_NODE}"
if [ $? -ne 0 ]
then
    echo "ERROR: sharp_manager.sh failed, check the log file"
    echo "FAIL"
    exit 1
fi

if [ "${SHARP_MANAGER_ACTION}" != "stop" ]
then
    verify_sharp
fi

rm -f ${SHARP_INI_FILE}

echo "PASS"
