/*
 * @Author : Alok Kumar Singh

 *Framework to handle governor limits on max 100 batch class in Flex queue.
*/
public class AsyncApexFramework extends AsyncApexFrameworkScheduler{
    private static Integer MAX_BATCHLIMIT = 100;
    private static Integer availableBatchLimit = null;
    private static List<AsyncQueue__c > lstBatch = new List<AsyncQueue__c >(); 
    private static Integer previousCount = -1;
    private static Integer MAX_RETRY = 2; 
    
    /*
     * GorvernerLimit available for DLM Operation.
    */
    private static Integer availableDMLLimit(){
        return Limits.getLimitDMLRows() - Limits.getDmlRows();
    }
    
    /*
     * This method in to submit the batch jobs.
     * @scopeSize - Chunk Size of Batch jobs.
     * @Priority- priority for the jobs , Default priority for every jobs are 99, when passed null or zero.
     * @allowRetryOnFail - If there is any exception or failed condition in job , retry should be attempted or not.
    */
    public static string submitBatch(Object batchClassInstance, Integer scopeSize, Integer priority , Boolean allowRetryOnFail){
        String jobId = null;
        if(priority == null ||priority == 0 ){
            priority = 99;
        }
        if(previousCount == -1){
            AggregateResult[] groupedResults = [Select Count(Id) FROM AsyncApexJob Where Status = 'Holding'];
            String exp0 = String.valueOf(groupedResults[0].get('expr0'));
            previousCount = Integer.valueOf(exp0) ;
        }  
        availableBatchLimit = MAX_BATCHLIMIT - previousCount;
        AsyncQueue__c  objAsyncQueue = new AsyncQueue__c (); 
        objAsyncQueue.Job_Type__c = 'Batch';
        objAsyncQueue.Batch_Size__c  = scopeSize;
        objAsyncQueue.priority__c = priority ; 
        objAsyncQueue.Is_Retry__c = allowRetryOnFail;
        objAsyncQueue.Retry_Count__c = 0;
        objAsyncQueue.Class_Name__c = String.valueOf(batchClassInstance).split(':')[0];
        
        if(availableBatchLimit > 0){  
            Database.batchable<sObject> b = (Database.batchable<sObject>)batchClassInstance; 
            objAsyncQueue.Job_Id__c = jobId = Database.executeBatch(b, scopeSize);
            objAsyncQueue.Status__c = 'Completed';   
            objAsyncQueue.Error_Collection_Status__c  = 'Not Collected';
        } 
        else{
            objAsyncQueue.Status__c = 'Queued';
        }
        lstBatch.add(objAsyncQueue);
        previousCount++;
        return jobId ;
    }
    
    /*
     * this is utility method is for adding the records of jobs in Database.
     * It will insert the records are clr the list.
    */
    public static void flush(){
        if(!lstBatch.isEmpty()){
            Database.insert(lstBatch,false);
            lstBatch.clear();
        }
    }
    
    /*
     * this method to get all the jobs which are pending from custom object.
    */
    private List<AsyncQueue__c> getPendingJobs(String jobType, Integer recordToFetch){
        return   [SELECT Batch_Size__c ,Class_Name__c,Retry_Count__c,Status__c FROM AsyncQueue__c
                  WHERE ( Status__c = 'Queued' OR (Status__c  = 'Failed' AND Error_Collection_Status__c  = 'Collected'  )) 
                  AND Is_Retry__c = true AND Job_Type__c = :jobType AND Retry_Count__c < : MAX_RETRY
                  Order By priority__c ASC LIMIT :recordToFetch ];
    }
    /* 
     * This method is for running the Batch Jobs for those which are in Queue or Failed.
     * And add the data to lstBatch_StatusUpdate list.
    */
    private void startBatchJobs(List<AsyncQueue__c > lstBatch_StatusUpdate){ 
        String jobId = null;
        Integer availableLimit = 0;
        AggregateResult[] groupedResults = [SELECT Count(Id) FROM AsyncApexJob WHERE Status = 'Holding'];
        String exp0 = String.valueOf(groupedResults[0].get('expr0'));
        availableLimit = MAX_BATCHLIMIT - Integer.valueOf(exp0);
        
        if(availableLimit > 50){
            availableLimit = 50;
        }
        
        if(availableLimit > 0){
            List<AsyncQueue__c > lstBatch = getPendingJobs('Batch', availableLimit)  ;
            if(!lstBatch.isEmpty()){
                for(AsyncQueue__c  objAsyncQueue : lstBatch){ 
                    try{
                        if(objAsyncQueue.Status__c == 'Failed'){
                            objAsyncQueue.Retry_Count__c = objAsyncQueue.Retry_Count__c + 1;
                        }else{
                            objAsyncQueue.Status__c = 'Completed'; 
                        }
                        Type batchClassType = Type.forName(objAsyncQueue.Class_Name__c);
                        Database.Batchable<sObject> batchInstance = (Database.Batchable<sObject>) batchClassType.newInstance();
                        objAsyncQueue.Job_Id__c = jobId = Database.executeBatch(batchInstance, Integer.valueOf(objAsyncQueue.Batch_Size__c));
                        objAsyncQueue.Error_Collection_Status__c  = 'Not Collected';
                        
                    }catch(Exception e){
                        objAsyncQueue.Status__c = 'Failed'; 
                        objAsyncQueue.Note__c = e.getMessage()+'\n'+e.getStackTraceString();
                    }
                    lstBatch_StatusUpdate.add(objAsyncQueue);
                }
            }   
        }         
    }
    /*
     * This method collects data from Saleforce Job logs(AsyncApexJob) and show on custom object.
    */
    private void collectJobInfo(List<AsyncQueue__c > lstBatch_StatusUpdate){
        Integer availableLimit = availableDMLLimit();  
        if(availableLimit > 0){ 
            List<AsyncQueue__c> listStatusCheck = [SELECT Job_Id__c,Note__c,Is_Retry__c,Status__c,Error_Collection_Status__c  FROM AsyncQueue__c
                                                   WHERE Error_Collection_Status__c  = 'Not Collected'
                                                   AND Status__c  IN ('Completed','Failed')   LIMIT :availableLimit ] ;
            Map<String,AsyncQueue__c> mpJobMap = new Map<String,AsyncQueue__c>();
            for(AsyncQueue__c objAsyncQueue : listStatusCheck){
                if(!string.isEmpty(objAsyncQueue.Job_Id__c)){
                    Id id15to18 = objAsyncQueue.Job_Id__c ;
                    mpJobMap.put(id15to18,objAsyncQueue); 
                } 
            } 
            
            if(mpJobMap.keyset().size() > 0){
                List<AsyncApexJob> lstJobStatus =[SELECT Id, ExtendedStatus, TotalJobItems  ,NumberOfErrors ,MethodName  
                                                  FROM AsyncApexJob WHERE Status IN ('Completed', 'Failed')  AND ID IN : mpJobMap.keyset()]; 
                for(AsyncApexJob objApexJob : lstJobStatus){ 
                    AsyncQueue__c objApexQueue = mpJobMap.get(objApexJob.Id); 
                    if(objApexQueue != null){
                        objApexQueue.Error_Collection_Status__c = 'Collected';
                        String note = '';
                        Note += String.isEmpty(objApexQueue.Note__c)? '' : objApexQueue.Note__c +'\n' ; 
                        if(!String.isEmpty(objApexJob.ExtendedStatus)){  
                            note+= String.isEmpty(objApexJob.ExtendedStatus)? '' : 'Error Messages - '+objApexJob.ExtendedStatus +'\n' ;  
                            objApexQueue.Status__c = 'Failed';
                        }else{
                            objApexQueue.Status__c = 'Completed'; 
                            objApexQueue.Is_Retry__c = false; 
                        }
                        Note += String.isEmpty(objApexJob.MethodName)? '' : 'Method - '+objApexJob.MethodName +'\n'; 
                        Note += 'Total Batches - '+objApexJob.TotalJobItems + '\n'; 
                        Note += 'Number of Errors - '+objApexJob.NumberOfErrors ;  
                        objApexQueue.Note__c = note;
                        lstBatch_StatusUpdate.add(objApexQueue);     
                    }
                }
            } 
        }
    }
    /*
     * Utility method to update status of Async Custom object records.
    */
    
    private void saveAsyncRecords(List<AsyncQueue__c > lstBatch_StatusUpdate){
        if(!lstBatch_StatusUpdate.isEmpty()){ 
            Database.update(lstBatch_StatusUpdate,false);
        } 
        lstBatch_StatusUpdate.clear(); 
    }
    /*
     * This method is for deleting the records which are completed with no Error.
    */
    private void toDelete(){
        Integer availableLimit = availableDMLLimit();  
        if(availableLimit > 0){
            List<AsyncQueue__c> deleteAsyncQueue = [SELECT Job_Id__c,Note__c,Is_Retry__c,Status__c  FROM AsyncQueue__c
                                                    WHERE Error_Collection_Status__c  = 'Collected'
                                                    AND Is_Retry__c = false AND CreatedDate <= YESTERDAY LIMIT:availableLimit];
            Database.delete(deleteAsyncQueue,false);
        }
    }   
    /*
     * Entry method by Scheduler
     * It will perform below 3 operations
     *  Schedule Batch if any in Queue.
     *  Collect results of these batches from Job Queue
     *  And it will Delete the records which is completed and Is_retry is false.
     */
    public void execute(SchedulableContext SC) { 
        List<AsyncQueue__c > lstBatch_StatusUpdate = new List<AsyncQueue__c >();
        toDelete();
        collectJobInfo(lstBatch_StatusUpdate); 
        saveAsyncRecords(lstBatch_StatusUpdate);
        startBatchJobs(lstBatch_StatusUpdate);
        saveAsyncRecords(lstBatch_StatusUpdate);
    }
}