import 'dotenv/config';
import crypto from "crypto";
import express from "express";
import sql from "mssql";
import cors from "cors";
import axios from "axios";
import bcrypt from "bcryptjs";
import cron from "node-cron";
import jwt from "jsonwebtoken";
import { v4 as uuidv4 } from "uuid";

const app = express();
app.use(express.json());
app.use(cors());

// Azure SQL config
const azureConfig = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  database: process.env.DB_NAME,
  options: { encrypt: true }
};

// AES Encryption Setup
const ALGO = "aes-256-gcm";
const KEY = Buffer.from(process.env.ENCRYPTION_KEY, "hex"); // 32-byte hex

// JWT Setup
const JWT_SECRET = process.env.JWT_SECRET

// Server steup for testing
const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`Server running on port ${port}`));

/*****************************************
 * HELPER FUNCTIONS
 *****************************************/
function encrypt(text) {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv(ALGO, KEY, iv);
  let encrypted = cipher.update(text, "utf8", "hex");
  encrypted += cipher.final("hex");
  const tag = cipher.getAuthTag().toString("hex");
  return { data: encrypted, iv: iv.toString("hex"), tag };
}

function decrypt({ data, iv, tag }) {
  const decipher = crypto.createDecipheriv(ALGO, KEY, Buffer.from(iv, "hex"));
  decipher.setAuthTag(Buffer.from(tag, "hex"));
  let decrypted = decipher.update(data, "hex", "utf8");
  decrypted += decipher.final("utf8");
  return decrypted;
}

async function hashPassword(plain) {
  const salt = await bcrypt.genSalt(10);
  return bcrypt.hash(plain, salt);
}

// Uses a shared secret to authenticate requests from the github 
function verifyCron(req, res, next) {
  const secret = req.header("x-cron-secret");

  if (!secret || secret !== process.env.CRON_SECRET) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  next();
}

// Uses a shared secret to authenticate requests from the Google Sheet
function verifySheets(req, res, next) {
  const key = req.header("x-sheets-key");

  if (!key || key !== process.env.SHEETS_API_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  req.user = { id: process.env.SHEETS_USER_ID };
  next();
}

// Uses the JWT to authenticate requests
function authRequired(req, res, next) {
  try {
    const auth = req.header("Authorization") || "";
    const [scheme, token] = auth.split(" ");

    if (scheme !== "Bearer" || !token) {
      return res.status(401).json({ success: false, message: "Missing or invalid Authorization header" });
    }

    const decoded = jwt.verify(token, JWT_SECRET);
    // decoded should contain { id, email } from your existing login/register code
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ success: false, message: "Invalid or expired token" });
  }
}

function toSqlDateTimeOffset(value) {
  const d = new Date(value);
  if (isNaN(d)) return null;

  // Truncate to milliseconds (Tedious-safe)
  d.setMilliseconds(Math.floor(d.getMilliseconds()));
  return d;
}

// This gets the date of 30 days ago and converts it to UNIX time, to be used in the simpleFin API call
function getUnixTime30DaysAgo() {
  const now = new Date();
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  return Math.floor(thirtyDaysAgo.getTime() / 1000);
}

// Returns the date 30 days ago formatted as YYYY-MM-DD, to be used in the Lunch Flow API call
function getDate30DaysAgo() {
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  return thirtyDaysAgo.toISOString().split('T')[0];
}

// Wrapper for any SQL Query to the DB to handle sleeping DB issues
async function queryWithRetry(callback, options = {}) {
  const maxRetries = options.maxRetries || 3;
  const retryDelay = options.retryDelay || 6000; // 5 seconds (balanced for DB wake-up time)
  const trackAttempts = options.trackAttempts || false; // New option to return attempt count
  
  let lastError;
  
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      console.log(`[DB] Connection attempt ${attempt}/${maxRetries}`);
      
      // Try to connect to the database
      const pool = await sql.connect(azureConfig);
      
      // Execute the callback with the connected pool
      const result = await callback(pool);
      
      console.log(`[DB] Connected successfully on attempt ${attempt}`);

      // If tracking attempts, wrap result with metadata
      if (trackAttempts) {

        return {
          success: true,
          data: result,
          attempts: attempt
        };
      }
      
      return result;
      
    } catch (err) {
      lastError = err;
      
      // Check if it's a connection error
      const isConnectionError = 
        err.code === 'ETIMEOUT' || 
        err.code === 'ESOCKET' ||
        (err.name === 'ConnectionError' && err.message.includes('Failed to connect'));
      
      if (isConnectionError && attempt < maxRetries) {
        console.log(`[DB] Connection failed (attempt ${attempt}/${maxRetries}): ${err.message}`);
        console.log(`[DB] Retrying in ${retryDelay/1000} seconds...`);
        
        // Wait before retrying
        await new Promise(resolve => setTimeout(resolve, retryDelay));
      } else {
        // Either it's not a connection error, or we've exhausted retries
        console.log(`[DB] Database operation failed:`, err.message);
        
        // If tracking attempts, wrap error with metadata
        if (trackAttempts) {
          return {
            success: false,
            error: err,
            attempts: attempt
          };
        }
        
        throw err;
      }
    }
  }
  
  // If we get here, all retries failed
  if (trackAttempts) {
    return {
      success: false,
      error: lastError,
      attempts: maxRetries
    };
  }
  
  throw lastError;
}

// Shared function to sync SimpleFIN data for a single user
async function syncSimpleFinDataForUser(user) {
  // Decrypt the accessURL
  const accessUrl = decrypt({
    data: user.simpleFinAccessURLData,
    iv: user.simpleFinAccessURLIV,
    tag: user.simpleFinAccessURLTag
  });

  // Fetch data from SimpleFIN
  const simpleFinResponse = await axios.get(
    `${accessUrl}/accounts`,
    {
      params: {
        pending: 1,
        include: 'transactions',
        'start-date': getUnixTime30DaysAgo()
      }
    }
  );

  const accounts = simpleFinResponse.data.accounts;
  const simpleFinErrors = simpleFinResponse.data.errors || [];
  console.log(`[SYNC] User ${user.id}: Fetched ${accounts.length} accounts from SimpleFin`);

  // Process accounts and transactions within a database transaction
  const stats = await queryWithRetry(async (pool) => {
    const transaction = new sql.Transaction(pool);
    await transaction.begin();

    let accountsUpdated = 0;
    let accountsAdded = 0;
    let transactionsInserted = 0;
    let pendingTransactionsRemoved = 0;

    try {
      for (const account of accounts) {
        // Get the user's account from DB to check if it exists (lookup by externalID + userID)
        const existingAccountQuery = await new sql.Request(transaction)
          .input("externalId", sql.VarChar(100), account.id)
          .input("userId", sql.UniqueIdentifier, user.id)
          .query(`
            SELECT internalID, balance, availableBalance
            FROM Accounts
            WHERE externalID = @externalId AND userID = @userId
          `);

        // Convert the format of balance, available-balance, and balance-date
        const availableBalance = parseFloat(account["available-balance"]) || 0;
        const balance = parseFloat(account["balance"]) || 0;
        const balanceDate = account["balance-date"]
          ? new Date(account["balance-date"] * 1000)
          : null;

        let accountInternalID;

        // If account doesn't exist in our DB, add it with accountType '-'
        if (existingAccountQuery.recordset.length === 0) {

          // Extract the account number from the name
          const match = account.name.match(/\((\d+)\)/);
          const accountNumber = match ? match[1] : null;
          const cleanedName = account.name.replace(/\s*\(\d+\)/, "").trim();
          accountInternalID = uuidv4();

          await new sql.Request(transaction)
            .input("internalID", sql.UniqueIdentifier, accountInternalID)
            .input("externalID", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, user.id)
            .input("accountSource", sql.NVarChar(255), "SimpleFIN")
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .input("accountType", sql.VarChar(50), '-')
            .query(`
              INSERT INTO Accounts (
                internalID, externalID, userID, name, bank, accountSource, accountNumber, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt
              )
              VALUES (
                @internalID, @externalID, @userID, @name, @bank, @accountSource, @accountNumber, @availableBalance, @balance, @balanceDate, @accountType, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          accountsAdded++;
        } else {
          accountInternalID = existingAccountQuery.recordset[0].internalID;
          await new sql.Request(transaction)
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              UPDATE Accounts
              SET availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHERE internalID = @accountInternalID
            `);
          accountsUpdated++;
        }

        // If account is new or balances changed, add a new accountBalanceHistory row
        const isNew = existingAccountQuery.recordset.length === 0;
        const existing = isNew ? null : existingAccountQuery.recordset[0];
        const balanceChanged = isNew || parseFloat(existing.balance) !== balance || parseFloat(existing.availableBalance) !== availableBalance;

        if (balanceChanged) {
          await new sql.Request(transaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("availableBalance", sql.Decimal(18, 2), availableBalance)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              INSERT INTO AccountBalanceHistory (
                id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
              )
              VALUES (
                @id, @accountInternalID, @availableBalance, @balance, @balanceDate, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);
        }

        // Insert transactions
        const simpleFinTxnIds = account.transactions
          ? account.transactions.map(txn => txn.id)
          : [];

        // Remove orphaned pending transactions (lookup by accountInternalID)
        const orphanedTxns = await new sql.Request(transaction)
          .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
          .query(`
            SELECT internalID, externalID
            FROM Transactions
            WHERE accountInternalID = @accountInternalID AND pending = 1
          `);

        for (const dbTxn of orphanedTxns.recordset) {
          if (!simpleFinTxnIds.includes(dbTxn.externalID)) {
            // Unlink any payment/transfer matched to this pending txn (they stay completed and get re-matched
            // to the posted version by /sheets/check-payments), then delete it
            await new sql.Request(transaction)
              .input("txnInternalID", sql.UniqueIdentifier, dbTxn.internalID)
              .query(`
                UPDATE Payments SET matchedTransactionID = NULL, updatedAt = SYSUTCDATETIME() WHERE matchedTransactionID = @txnInternalID;
                UPDATE PaymentTransfers SET matchedTransactionID = NULL, updatedAt = SYSUTCDATETIME() WHERE matchedTransactionID = @txnInternalID;
                DELETE FROM Transactions WHERE internalID = @txnInternalID;
              `);

            pendingTransactionsRemoved++;
          }
        }

        // Insert/update transactions
        if (account.transactions) {
          // console.log(`[SYNC:SimpleFIN] Account "${account.name || account.id}" has ${account.transactions.length} transactions from SimpleFIN:`);
          // account.transactions.forEach(txn => {
          //   const txnDate = txn.posted ? new Date(txn.posted * 1000).toISOString() : 'no date';
          //   console.log(`  - [${txnDate}] "${txn.payee || 'Unknown'}" $${txn.amount} (id: ${txn.id}, pending: ${txn.pending || false})`);
          // });

          for (const txn of account.transactions) {
            const existingTxn = await new sql.Request(transaction)
              .input("txnExternalId", sql.VarChar(100), txn.id)
              .input("txnUserID", sql.UniqueIdentifier, user.id)
              .query(`SELECT internalID, pending FROM Transactions WHERE externalID = @txnExternalId AND userID = @txnUserID`);

            const txnDate = txn.posted
              ? new Date(txn.posted * 1000)
              : new Date();

            if (existingTxn.recordset.length === 0) {
              console.log(`  [SYNC:SimpleFIN] INSERT new txn: "${txn.payee || 'Unknown'}" ${txnDate.toISOString()}`);
              // Insert new transaction
              await new sql.Request(transaction)
                .input("internalID", sql.UniqueIdentifier, uuidv4())
                .input("externalID", sql.VarChar(100), txn.id)
                .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
                .input("userID", sql.UniqueIdentifier, user.id)
                .input("amount", sql.Decimal(18, 2), parseFloat(txn.amount) || 0)
                .input("name", sql.NVarChar(500), txn.payee || 'Unknown')
                .input("notes", sql.NVarChar(500), txn.description || '')
                .input("transactionDate", sql.DateTimeOffset, txnDate)
                .input("pending", sql.Bit, txn.pending || false)
                .query(`
                  INSERT INTO Transactions (
                    internalID, externalID, accountInternalID, userID, amount, name, notes,
                    transactionDate, pending, createdAt, updatedAt
                  )
                  VALUES (
                    @internalID, @externalID, @accountInternalID, @userID, @amount, @name, @notes,
                    @transactionDate, @pending, SYSUTCDATETIME(), SYSUTCDATETIME()
                  )
                `);

              transactionsInserted++;
            } else {
              // Update if pending status changed
              const existingPending = existingTxn.recordset[0].pending;
              const newPending = txn.pending || false;

              if (existingPending !== newPending) {
                await new sql.Request(transaction)
                  .input("txnInternalID", sql.UniqueIdentifier, existingTxn.recordset[0].internalID)
                  .input("pending", sql.Bit, newPending)
                  .input("transactionDate", sql.DateTimeOffset, txnDate)
                  .query(`
                    UPDATE Transactions
                    SET pending = @pending,
                        transactionDate = @transactionDate,
                        updatedAt = SYSUTCDATETIME()
                    WHERE internalID = @txnInternalID
                  `);
              }
            }
          }
        }
      }

      await transaction.commit();
      return { accountsUpdated, accountsAdded, transactionsInserted, pendingTransactionsRemoved, errors: simpleFinErrors };

    } catch (dbErr) {
      await transaction.rollback();
      throw dbErr;
    }
  });

  console.log(`[SYNC] User ${user.id}: SimpleFIN sync complete - ${stats.accountsUpdated} accounts updated, ${stats.accountsAdded} accounts added, ${stats.transactionsInserted} transactions inserted, ${stats.pendingTransactionsRemoved} pending transactions removed`);

  return stats;
}

// Shared function to sync Lunch Flow data for a single user
async function syncLunchFlowDataForUser(user) {
  const lunchFlowBaseURL = "https://www.lunchflow.app/api/v1";

  // Decrypt the API key
  const apiKey = decrypt({
    data: user.lunchFlowAPIKeyData,
    iv: user.lunchFlowAPIKeyIV,
    tag: user.lunchFlowAPIKeyTag
  });

  // Fetch accounts from Lunch Flow
  const lfResponse = await fetch(`${lunchFlowBaseURL}/accounts`, {
    method: "GET",
    headers: { "x-api-key": apiKey }
  });

  if (!lfResponse.ok) {
    throw new Error(`Lunch Flow API error: ${lfResponse.status}`);
  }

  const body = await lfResponse.json();
  const accounts = body.accounts || body || [];

  console.log(`[SYNC] User ${user.id}: Fetched ${accounts.length} accounts from Lunch Flow`);

  // Fetch balances and transactions for all accounts in parallel
  const [balanceResults, transactionResults] = await Promise.all([
    Promise.all(
      accounts.map(account =>
        fetch(`${lunchFlowBaseURL}/accounts/${account.id}/balance`, {
          method: "GET",
          headers: { "x-api-key": apiKey }
        })
        .then(res => {
          if (!res.ok) throw new Error(`Balance fetch failed: ${res.status}`);
          return res.json();
        })
        .then(balanceData => ({ accountId: account.id, balanceData }))
      )
    ),
    Promise.all(
      accounts.map(account =>
        fetch(`${lunchFlowBaseURL}/accounts/${account.id}/transactions?from=${getDate30DaysAgo()}&include_pending=true`, {
          method: "GET",
          headers: { "x-api-key": apiKey }
        })
        .then(res => {
          if (!res.ok) throw new Error(`Transactions fetch failed: ${res.status}`);
          return res.json();
        })
        .then(data => ({ accountId: account.id, transactions: data.transactions || [] }))
      )
    )
  ]);

  const balanceMap = new Map(balanceResults.map(b => [b.accountId, b.balanceData]));
  const transactionMap = new Map(transactionResults.map(t => [t.accountId, t.transactions]));

  const stats = await queryWithRetry(async (pool) => {
    const transaction = new sql.Transaction(pool);
    await transaction.begin();

    let accountsUpdated = 0;
    let accountsAdded = 0;
    let transactionsInserted = 0;
    let pendingTransactionsRemoved = 0;

    try {
      for (const account of accounts) {
        const balanceData = balanceMap.get(account.id);
        const rawBalance =
          balanceData?.balance ??
          balanceData?.current_balance ??
          balanceData?.amount ??
          0;
        const balance = parseFloat(rawBalance?.amount ?? rawBalance) || 0;

        // Lookup by externalID + userID
        const existingAccountQuery = await new sql.Request(transaction)
          .input("externalId", sql.VarChar(100), String(account.id))
          .input("userId", sql.UniqueIdentifier, user.id)
          .query(`
            SELECT internalID, balance, availableBalance
            FROM Accounts
            WHERE externalID = @externalId AND userID = @userId
          `);

        let accountInternalID;

        if (existingAccountQuery.recordset.length === 0) {
          // Insert new account
          accountInternalID = uuidv4();
          await new sql.Request(transaction)
            .input("internalID", sql.UniqueIdentifier, accountInternalID)
            .input("externalID", sql.VarChar(100), String(account.id))
            .input("userID", sql.UniqueIdentifier, user.id)
            .input("name", sql.NVarChar(255), account.name || "Unnamed")
            .input("bank", sql.NVarChar(255), account.institution_name || null)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("availableBalance", sql.Decimal(18, 2), balance)
            .query(`
              INSERT INTO Accounts (
                internalID, externalID, userID, name, bank, accountSource,
                availableBalance, balance, balanceDate,
                accountType, createdAt, updatedAt
              )
              VALUES (
                @internalID, @externalID, @userID, @name, @bank, 'Lunch Flow',
                @availableBalance, @balance, SYSUTCDATETIME(),
                '-', SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          // Record initial balance history
          await new sql.Request(transaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
            .input("balance", sql.Decimal(18, 2), balance)
            .input("availableBalance", sql.Decimal(18, 2), balance)
            .query(`
              INSERT INTO AccountBalanceHistory (
                id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
              )
              VALUES (
                @id, @accountInternalID, @availableBalance, @balance, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);

          accountsAdded++;

        } else {
          // Update existing account
          accountInternalID = existingAccountQuery.recordset[0].internalID;
          const existing = existingAccountQuery.recordset[0];
          const balanceChanged =
            parseFloat(existing.balance) !== balance ||
            parseFloat(existing.availableBalance) !== balance;

          if (balanceChanged) {
            await new sql.Request(transaction)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                UPDATE Accounts
                SET balance = @balance,
                    availableBalance = @availableBalance,
                    balanceDate = SYSUTCDATETIME(),
                    updatedAt = SYSUTCDATETIME()
                WHERE internalID = @accountInternalID
              `);

            await new sql.Request(transaction)
              .input("id", sql.UniqueIdentifier, uuidv4())
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                INSERT INTO AccountBalanceHistory (
                  id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
                )
                VALUES (
                  @id, @accountInternalID, @availableBalance, @balance, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              `);
          } else {
            await new sql.Request(transaction)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("balance", sql.Decimal(18, 2), balance)
              .input("availableBalance", sql.Decimal(18, 2), balance)
              .query(`
                UPDATE Accounts
                SET balance = @balance,
                    availableBalance = @availableBalance,
                    updatedAt = SYSUTCDATETIME()
                WHERE internalID = @accountInternalID
              `);
          }

          accountsUpdated++;
        }

        // Sync transactions for this account
        const lfTxns = transactionMap.get(account.id) || [];
        const lfTxnIds = lfTxns.map(txn => String(txn.id));

        // Remove orphaned pending transactions no longer in the Lunch Flow response
        const orphanedTxns = await new sql.Request(transaction)
          .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
          .query(`
            SELECT internalID, externalID
            FROM Transactions
            WHERE accountInternalID = @accountInternalID AND pending = 1
          `);

        for (const dbTxn of orphanedTxns.recordset) {
          if (!lfTxnIds.includes(dbTxn.externalID)) {
            // Unlink any payment/transfer matched to this pending txn (they stay completed and get re-matched
            // to the posted version by /sheets/check-payments), then delete it
            await new sql.Request(transaction)
              .input("txnInternalID", sql.UniqueIdentifier, dbTxn.internalID)
              .query(`
                UPDATE Payments SET matchedTransactionID = NULL, updatedAt = SYSUTCDATETIME() WHERE matchedTransactionID = @txnInternalID;
                UPDATE PaymentTransfers SET matchedTransactionID = NULL, updatedAt = SYSUTCDATETIME() WHERE matchedTransactionID = @txnInternalID;
                DELETE FROM Transactions WHERE internalID = @txnInternalID;
              `);

            pendingTransactionsRemoved++;
          }
        }

        // // Insert/update transactions
        // console.log(`[SYNC:LunchFlow] Account "${account.name || account.id}" has ${lfTxns.length} transactions from Lunch Flow:`);
        // lfTxns.forEach(txn => {
        //   const txnDate = txn.date ? new Date(txn.date).toISOString() : 'no date';
        //   console.log(`  - [${txnDate}] "${txn.merchant || 'Unknown'}" $${txn.amount} (id: ${txn.id}, pending: ${txn.isPending || false})`);
        // });

        for (const txn of lfTxns) {
          if (!txn.id) continue;

          const txnExternalId = String(txn.id);
          const txnDate = txn.date ? new Date(txn.date) : new Date();
          const isPending = txn.isPending || false;

          const existingTxn = await new sql.Request(transaction)
            .input("txnExternalId", sql.VarChar(100), txnExternalId)
            .input("txnUserID", sql.UniqueIdentifier, user.id)
            .query(`SELECT internalID, pending FROM Transactions WHERE externalID = @txnExternalId AND userID = @txnUserID`);

          if (existingTxn.recordset.length === 0) {
            console.log(`  [SYNC:LunchFlow] INSERT new txn: "${txn.merchant || 'Unknown'}" ${txnDate.toISOString()}`);
            await new sql.Request(transaction)
              .input("internalID", sql.UniqueIdentifier, uuidv4())
              .input("externalID", sql.VarChar(100), txnExternalId)
              .input("accountInternalID", sql.UniqueIdentifier, accountInternalID)
              .input("userID", sql.UniqueIdentifier, user.id)
              .input("amount", sql.Decimal(18, 2), parseFloat(txn.amount) || 0)
              .input("name", sql.NVarChar(500), txn.merchant || "Unknown")
              .input("notes", sql.NVarChar(500), txn.description || "")
              .input("transactionDate", sql.DateTimeOffset, txnDate)
              .input("pending", sql.Bit, isPending)
              .query(`
                INSERT INTO Transactions (
                  internalID, externalID, accountInternalID, userID, amount, name, notes,
                  transactionDate, pending, createdAt, updatedAt
                )
                VALUES (
                  @internalID, @externalID, @accountInternalID, @userID, @amount, @name, @notes,
                  @transactionDate, @pending, SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              `);

            transactionsInserted++;
          } else {
            // Update if pending status changed
            const existingPending = existingTxn.recordset[0].pending;

            if (existingPending !== isPending) {
              await new sql.Request(transaction)
                .input("txnInternalID", sql.UniqueIdentifier, existingTxn.recordset[0].internalID)
                .input("pending", sql.Bit, isPending)
                .input("transactionDate", sql.DateTimeOffset, txnDate)
                .query(`
                  UPDATE Transactions
                  SET pending = @pending,
                      transactionDate = @transactionDate,
                      updatedAt = SYSUTCDATETIME()
                  WHERE internalID = @txnInternalID
                `);
            }
          }
        }
      }

      await transaction.commit();
      return { accountsUpdated, accountsAdded, transactionsInserted, pendingTransactionsRemoved };

    } catch (dbErr) {
      await transaction.rollback();
      throw dbErr;
    }
  });

  console.log(`[SYNC] User ${user.id}: Lunch Flow sync complete - ${stats.accountsUpdated} accounts updated, ${stats.accountsAdded} accounts added, ${stats.transactionsInserted} transactions inserted, ${stats.pendingTransactionsRemoved} pending transactions removed`);

  return stats;
}

/*****************************************
 * API Endpoints
 *****************************************/

// ******* General Endpoints *******

// Return the current status of the server and DB
app.get("/status", async (req, res, next) => {
  try {
    // Server is always "up" if we can respond
    const serverStatus = {
      status: "up",
      timestamp: new Date().toISOString()
    };

    const startTime = Date.now();

    // Use queryWithRetry with attempt tracking enabled
    const dbResult = await queryWithRetry(
      async (pool) => {
        await pool.request().query('SELECT 1 AS healthCheck');
        return true; // Just return success indicator
      },
      {
        maxRetries: 3,
        retryDelay: 5000, // 5 seconds for health checks
        trackAttempts: true // Enable attempt tracking
      }
    );

    const responseTime = Date.now() - startTime;

    // Build database status from the result
    let dbStatus;
    
    if (dbResult.success) {
      dbStatus = {
        status: "up",
        message: dbResult.attempts === 1 
          ? "Connected immediately" 
          : `Connected after ${dbResult.attempts} attempts`,
        responseTime: `${responseTime}ms`,
        attempts: dbResult.attempts
      };
    } else {
      dbStatus = {
        status: "down",
        message: dbResult.error?.code === 'ETIMEOUT' || dbResult.error?.name === 'ConnectionError'
          ? `Database unreachable after ${dbResult.attempts} attempts`
          : "Database error occurred",
        responseTime: `${responseTime}ms`,
        attempts: dbResult.attempts,
        error: dbResult.error?.message
      };
    }

    // Return overall status
    res.json({
      server: serverStatus,
      database: dbStatus,
      overall: dbStatus.status === "up" ? "healthy" : "degraded"
    });

  } catch (err) {
    next(err);
  }
});

// Internal call from GitHub action to refresh the DB with latest bank data
app.post("/internal/sync-connected-bank-data", verifyCron, async (req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all users that have at least one connected service
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE (simpleFinAccessURLData IS NOT NULL AND simpleFinAccessURLIV IS NOT NULL AND simpleFinAccessURLTag IS NOT NULL)
             OR (lunchFlowAPIKeyData IS NOT NULL AND lunchFlowAPIKeyIV IS NOT NULL AND lunchFlowAPIKeyTag IS NOT NULL)
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with connected accounts`);

    // Process each user using shared sync functions
    for (const user of usersWithAccess) {
      try {
        const hasSimpleFin = user.simpleFinAccessURLData && user.simpleFinAccessURLIV && user.simpleFinAccessURLTag;
        const hasLunchFlow = user.lunchFlowAPIKeyData && user.lunchFlowAPIKeyIV && user.lunchFlowAPIKeyTag;

        const [simpleFinStats, lunchFlowStats] = await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
        ]);

        usersProcessed++;

        for (const stats of [simpleFinStats, lunchFlowStats]) {
          if (!stats) continue;
          totalAccountsUpdated += stats.accountsUpdated;
          totalAccountsAdded += stats.accountsAdded;
          totalTransactionsInserted += stats.transactionsInserted;
          totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;
        }

      } catch (userErr) {
        console.error(`[SYNC] Error processing user ${user.id}:`, userErr.message);
        errors.push({
          userId: user.id,
          error: userErr.message
        });
      }
    }

    res.json({
      success: true,
      message: `Sync complete: ${usersProcessed} users processed`,
      stats: {
        usersProcessed,
        totalAccountsUpdated,
        totalAccountsAdded,
        totalTransactionsInserted,
        totalPendingTransactionsRemoved,
        errors: errors.length > 0 ? errors : undefined
      }
    });

  } catch (err) {
    next(err);
  }
});

// Manual call to refresh the DB with latest bank data
app.post("/manual/sync-connected-bank-data", async (_req, res, next) => {
  try {
    let usersProcessed = 0;
    let totalAccountsUpdated = 0;
    let totalAccountsAdded = 0;
    let totalTransactionsInserted = 0;
    let totalPendingTransactionsRemoved = 0;
    const errors = [];

    // Get all users that have at least one connected service
    const usersWithAccess = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE (simpleFinAccessURLData IS NOT NULL AND simpleFinAccessURLIV IS NOT NULL AND simpleFinAccessURLTag IS NOT NULL)
             OR (lunchFlowAPIKeyData IS NOT NULL AND lunchFlowAPIKeyIV IS NOT NULL AND lunchFlowAPIKeyTag IS NOT NULL)
        `);
      return result.recordset;
    });

    console.log(`[SYNC] Found ${usersWithAccess.length} users with connected accounts`);

    // Process each user using shared sync functions
    for (const user of usersWithAccess) {
      try {
        const hasSimpleFin = user.simpleFinAccessURLData && user.simpleFinAccessURLIV && user.simpleFinAccessURLTag;
        const hasLunchFlow = user.lunchFlowAPIKeyData && user.lunchFlowAPIKeyIV && user.lunchFlowAPIKeyTag;

        const [simpleFinStats, lunchFlowStats] = await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
        ]);

        usersProcessed++;

        for (const stats of [simpleFinStats, lunchFlowStats]) {
          if (!stats) continue;
          totalAccountsUpdated += stats.accountsUpdated;
          totalAccountsAdded += stats.accountsAdded;
          totalTransactionsInserted += stats.transactionsInserted;
          totalPendingTransactionsRemoved += stats.pendingTransactionsRemoved;
        }

      } catch (userErr) {
        console.error(`[SYNC] Error processing user ${user.id}:`, userErr.message);
        errors.push({
          userId: user.id,
          error: userErr.message
        });
      }
    }

    res.json({
      success: true,
      message: `Sync complete: ${usersProcessed} users processed`,
      stats: {
        usersProcessed,
        totalAccountsUpdated,
        totalAccountsAdded,
        totalTransactionsInserted,
        totalPendingTransactionsRemoved,
        errors: errors.length > 0 ? errors : undefined
      }
    });

  } catch (err) {
    next(err);
  }
});

// Gets all transactions for one of the User's accounts




// ******* Google Sheet Specific Endpoints *******

// Trigger from the google sheet to update Azure DB with new SimpleFIN / LunchFlow data
app.post("/sheets/sync", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets

    console.log(`[SYNC] Starting sheets sync for user ${userID}`);

    // Get user's credentials for all connected services
    const user = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE id = @userID
        `);
      return result.recordset[0];
    });

    const hasSimpleFin = user?.simpleFinAccessURLData && user?.simpleFinAccessURLIV && user?.simpleFinAccessURLTag;
    const hasLunchFlow = user?.lunchFlowAPIKeyData && user?.lunchFlowAPIKeyIV && user?.lunchFlowAPIKeyTag;

    if (!hasSimpleFin && !hasLunchFlow) {
      return res.json({
        success: false,
        message: "No connected accounts found for user"
      });
    }

    // Run all available syncs in parallel
    const [simpleFinStats, lunchFlowStats] = await Promise.all([
      hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
      hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
    ]);

    res.json({
      success: true,
      message: "Sync complete",
      stats: { simpleFin: simpleFinStats, lunchFlow: lunchFlowStats }
    });

  } catch (err) {
    next(err);
  }
});

// Create a new payment, Sheets always sets Bills as the account making the payment
app.post("/sheets/make-payment", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets
    const { name, paymentAmount, creditAccountExternalID, billsAccountExternalID, paymentTransfers } = req.body;

    // The sheets key only grants access to SHEETS_USER_ID, so a different userID in the body is rejected
    if (req.body.userID && req.body.userID.toLowerCase() !== userID.toLowerCase()) {
      return res.status(403).json({ success: false, message: "userID does not match the sheets key" });
    }

    if (name == null || String(name).trim() === "" || typeof paymentAmount !== "number" || !creditAccountExternalID || !billsAccountExternalID) {
      return res.status(400).json({
        success: false,
        message: "name, paymentAmount, creditAccountExternalID, and billsAccountExternalID are all required"
      });
    }

    if (creditAccountExternalID === billsAccountExternalID) {
      return res.status(400).json({ success: false, message: "The credit account and bills account must be different" });
    }

    const transfers = Array.isArray(paymentTransfers) ? paymentTransfers : [];
    if (transfers.some(t => !t.accountID || typeof t.amount !== "number")) {
      return res.status(400).json({ success: false, message: "Each paymentTransfer needs an accountID and a numeric amount" });
    }

    // External IDs of the credit card transactions this payment covers
    const transactionExternalIDs = [...new Set(Array.isArray(req.body.transactions) ? req.body.transactions : [])];
    if (transactionExternalIDs.some(id => typeof id !== "string" || id.trim() === "")) {
      return res.status(400).json({ success: false, message: "transactions must be an array of external transaction IDs" });
    }

    const paymentName = String(name).trim();
    const paymentID = uuidv4();

    const result = await queryWithRetry(async (pool) => {
      // Look up the internalIDs of every external account ID, only within this user's accounts
      const externalIDs = [...new Set([creditAccountExternalID, billsAccountExternalID, ...transfers.map(t => t.accountID)])];
      const lookup = pool.request().input("userID", sql.UniqueIdentifier, userID);
      externalIDs.forEach((extID, i) => lookup.input(`ext${i}`, sql.VarChar(50), extID));

      const accountsResult = await lookup.query(`
        SELECT internalID, externalID
        FROM Accounts
        WHERE userID = @userID AND externalID IN (${externalIDs.map((_, i) => `@ext${i}`).join(", ")})
      `);

      const internalIDByExternal = {};
      for (const row of accountsResult.recordset) {
        internalIDByExternal[row.externalID] = row.internalID;
      }

      const missing = externalIDs.filter(extID => !internalIDByExternal[extID]);
      if (missing.length > 0) {
        return { missing };
      }

      // Payment names are unique per user (same rule the app enforces)
      const existing = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), paymentName)
        .query(`SELECT id FROM Payments WHERE userID = @userID AND LOWER(name) = LOWER(@name)`);

      if (existing.recordset.length > 0) {
        return { duplicateName: true };
      }

      // Look up the credit card transactions to link, only within this user's credit account
      let transactionInternalIDs = [];
      if (transactionExternalIDs.length > 0) {
        const txnLookup = pool.request()
          .input("userID", sql.UniqueIdentifier, userID)
          .input("creditAccountInternalID", sql.UniqueIdentifier, internalIDByExternal[creditAccountExternalID]);
        transactionExternalIDs.forEach((extID, i) => txnLookup.input(`txn${i}`, sql.VarChar(50), extID));

        const txnResult = await txnLookup.query(`
          SELECT t.internalID, t.externalID, t.paymentID, p.name AS paymentName
          FROM Transactions t
          LEFT JOIN Payments p ON t.paymentID = p.id
          WHERE t.userID = @userID
            AND t.accountInternalID = @creditAccountInternalID
            AND t.externalID IN (${transactionExternalIDs.map((_, i) => `@txn${i}`).join(", ")})
        `);

        const foundExternalIDs = new Set(txnResult.recordset.map(t => t.externalID));
        const missingTransactions = transactionExternalIDs.filter(extID => !foundExternalIDs.has(extID));
        if (missingTransactions.length > 0) {
          return { missingTransactions };
        }

        // Don't silently move a transaction out of a payment it already belongs to
        const alreadyLinked = txnResult.recordset.filter(t => t.paymentID);
        if (alreadyLinked.length > 0) {
          return { alreadyLinked: alreadyLinked.map(t => `${t.externalID} (payment "${t.paymentName}")`) };
        }

        transactionInternalIDs = txnResult.recordset.map(t => t.internalID);
      }

      // Create the payment and its transfers atomically
      const dbTransaction = new sql.Transaction(pool);
      await dbTransaction.begin();

      try {
        await new sql.Request(dbTransaction)
          .input("id", sql.UniqueIdentifier, paymentID)
          .input("name", sql.NVarChar(255), paymentName)
          .input("paymentAmount", sql.Decimal(18, 2), paymentAmount)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("creditAccountInternalID", sql.UniqueIdentifier, internalIDByExternal[creditAccountExternalID])
          .input("paidFromAccountInternalID", sql.UniqueIdentifier, internalIDByExternal[billsAccountExternalID])
          .query(`
            INSERT INTO Payments (
              id, name, paymentAmount, userID, creditAccountInternalID, paidFromAccountInternalID, createdAt, updatedAt
            )
            VALUES (
              @id, @name, @paymentAmount, @userID, @creditAccountInternalID, @paidFromAccountInternalID, SYSUTCDATETIME(), SYSUTCDATETIME()
            )
          `);

        // One transfer per account moving its share into the bills account
        for (const transfer of transfers) {
          await new sql.Request(dbTransaction)
            .input("id", sql.UniqueIdentifier, uuidv4())
            .input("transferAmount", sql.Decimal(18, 2), transfer.amount)
            .input("paymentID", sql.UniqueIdentifier, paymentID)
            .input("accountInternalID", sql.UniqueIdentifier, internalIDByExternal[transfer.accountID])
            .query(`
              INSERT INTO PaymentTransfers (
                id, transferAmount, paymentID, accountInternalID, createdAt, updatedAt
              )
              VALUES (
                @id, @transferAmount, @paymentID, @accountInternalID, SYSUTCDATETIME(), SYSUTCDATETIME()
              )
            `);
        }

        // Link the credit card transactions to this payment
        for (const transactionInternalID of transactionInternalIDs) {
          await new sql.Request(dbTransaction)
            .input("paymentID", sql.UniqueIdentifier, paymentID)
            .input("transactionID", sql.UniqueIdentifier, transactionInternalID)
            .query(`
              UPDATE Transactions
              SET paymentID = @paymentID, updatedAt = SYSUTCDATETIME()
              WHERE internalID = @transactionID
            `);
        }

        await dbTransaction.commit();
      } catch (dbErr) {
        await dbTransaction.rollback();
        throw dbErr;
      }

      return { linkedTransactions: transactionInternalIDs.length };
    });

    if (result.missing) {
      return res.status(404).json({
        success: false,
        message: "No account found for these external IDs: " + result.missing.join(", ")
      });
    }

    if (result.missingTransactions) {
      return res.status(404).json({
        success: false,
        message: "No transaction on the credit account found for these external IDs: " + result.missingTransactions.join(", ")
      });
    }

    if (result.alreadyLinked) {
      return res.status(409).json({
        success: false,
        message: "These transactions already belong to another payment: " + result.alreadyLinked.join(", ")
      });
    }

    res.json({ success: true, message: "Payment created", paymentID, linkedTransactions: result.linkedTransactions });

  } catch (err) {
    next(err);
  }
});

// Check for transactions in the account the match a Payment or PaymentTranfer.\
app.post("/sheets/check-payments", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets

    // The sheets key only grants access to SHEETS_USER_ID, so a different userID in the body is rejected
    if (req.body?.userID && req.body.userID.toLowerCase() !== userID.toLowerCase()) {
      return res.status(403).json({ success: false, message: "userID does not match the sheets key" });
    }

    const DAY_MS = 24 * 60 * 60 * 1000;
    const toCents = (amount) => Math.round(Math.abs(Number(amount)) * 100);

    const result = await queryWithRetry(async (pool) => {
      // Payments that need a transaction: not completed yet, or completed but their matched
      // pending transaction was deleted by the sync (needs re-linking to the posted version)
      const paymentsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT p.id, p.name, p.paymentAmount, p.completed, p.paidFromAccountInternalID, p.createdAt,
                 a.name AS accountName
          FROM Payments p
          LEFT JOIN Accounts a ON p.paidFromAccountInternalID = a.internalID
          WHERE p.userID = @userID
            AND p.paidFromAccountInternalID IS NOT NULL
            AND (p.completed = 0 OR p.matchedTransactionID IS NULL)
          ORDER BY p.createdAt ASC
        `);

      // PaymentTransfers that need a transaction, same rule
      const transfersResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT pt.id, pt.paymentID, pt.transferAmount, pt.completed, pt.accountInternalID, p.name AS paymentName, p.createdAt,
                 a.name AS accountName
          FROM PaymentTransfers pt
          INNER JOIN Payments p ON pt.paymentID = p.id
          LEFT JOIN Accounts a ON pt.accountInternalID = a.internalID
          WHERE p.userID = @userID
            AND (pt.completed = 0 OR pt.matchedTransactionID IS NULL)
          ORDER BY p.createdAt ASC
        `);

      const openPayments = paymentsResult.recordset;
      const openTransfers = transfersResult.recordset;

      if (openPayments.length === 0 && openTransfers.length === 0) {
        return { matchedPayments: [], matchedTransfers: [], stillOpen: [], unlinked: [] };
      }

      // Get candidate transactions (pending or posted): outgoing, on the accounts involved, since the day before
      // the oldest payment that needs one, and not already matched to another payment or transfer
      const accountIDs = [...new Set([
        ...openPayments.map(p => p.paidFromAccountInternalID),
        ...openTransfers.map(t => t.accountInternalID)
      ])];
      const oldestCreatedAt = new Date(
        Math.min(...[...openPayments, ...openTransfers].map(item => new Date(item.createdAt).getTime())) - DAY_MS
      );

      const candidatesRequest = pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("since", sql.DateTimeOffset, oldestCreatedAt);
      accountIDs.forEach((id, i) => candidatesRequest.input(`acct${i}`, sql.UniqueIdentifier, id));

      const candidatesResult = await candidatesRequest.query(`
        SELECT t.internalID, t.externalID, t.accountInternalID, t.amount, t.name, t.transactionDate, t.pending
        FROM Transactions t
        WHERE t.userID = @userID
          AND t.amount < 0
          AND t.transactionDate >= @since
          AND t.accountInternalID IN (${accountIDs.map((_, i) => `@acct${i}`).join(", ")})
          AND NOT EXISTS (SELECT 1 FROM Payments p2 WHERE p2.matchedTransactionID = t.internalID)
          AND NOT EXISTS (SELECT 1 FROM PaymentTransfers pt2 WHERE pt2.matchedTransactionID = t.internalID)
        ORDER BY t.transactionDate ASC
      `);

      const candidates = candidatesResult.recordset;
      const usedTransactionIDs = new Set();

      // Earliest unused transaction on the account for the same amount, on or after the day before the payment
      // was created. A posted transaction is preferred over a pending one when both exist.
      function findMatch(accountInternalID, amount, createdAt) {
        const earliest = new Date(createdAt).getTime() - DAY_MS;
        const matches = candidates.filter(t =>
          !usedTransactionIDs.has(t.internalID) &&
          t.accountInternalID === accountInternalID &&
          toCents(t.amount) === toCents(amount) &&
          new Date(t.transactionDate).getTime() >= earliest
        );
        const match = matches.find(t => !t.pending) || matches[0];
        if (match) usedTransactionIDs.add(match.internalID);
        return match;
      }

      // Match oldest payments first so an older payment claims the earlier transaction
      const matchedPayments = [];
      const matchedTransfers = [];
      const stillOpen = [];  // not completed, no transaction found yet
      const unlinked = [];   // completed, but its transaction was deleted and no replacement was found yet

      for (const payment of openPayments) {
        const match = findMatch(payment.paidFromAccountInternalID, payment.paymentAmount, payment.createdAt);
        const summary = { type: "payment", paymentName: payment.name, accountName: payment.accountName, amount: payment.paymentAmount };
        if (match) {
          matchedPayments.push({ payment, match });
        } else {
          (payment.completed ? unlinked : stillOpen).push(summary);
        }
      }

      for (const transfer of openTransfers) {
        const match = findMatch(transfer.accountInternalID, transfer.transferAmount, transfer.createdAt);
        const summary = { type: "transfer", paymentName: transfer.paymentName, accountName: transfer.accountName, amount: transfer.transferAmount };
        if (match) {
          matchedTransfers.push({ transfer, match });
        } else {
          (transfer.completed ? unlinked : stillOpen).push(summary);
        }
      }

      // Save the matches and update completion flags atomically
      const dbTransaction = new sql.Transaction(pool);
      await dbTransaction.begin();

      try {
        for (const { payment, match } of matchedPayments) {
          await new sql.Request(dbTransaction)
            .input("id", sql.UniqueIdentifier, payment.id)
            .input("transactionID", sql.UniqueIdentifier, match.internalID)
            .query(`
              UPDATE Payments
              SET matchedTransactionID = @transactionID, completed = 1, updatedAt = SYSUTCDATETIME()
              WHERE id = @id
            `);
        }

        for (const { transfer, match } of matchedTransfers) {
          await new sql.Request(dbTransaction)
            .input("id", sql.UniqueIdentifier, transfer.id)
            .input("transactionID", sql.UniqueIdentifier, match.internalID)
            .query(`
              UPDATE PaymentTransfers
              SET matchedTransactionID = @transactionID, completed = 1, updatedAt = SYSUTCDATETIME()
              WHERE id = @id
            `);
        }

        // A payment is fully completed once it and all of its transfers are completed
        await new sql.Request(dbTransaction)
          .input("userID", sql.UniqueIdentifier, userID)
          .query(`
            UPDATE p
            SET p.fullyCompleted = 1, p.updatedAt = SYSUTCDATETIME()
            FROM Payments p
            WHERE p.userID = @userID
              AND p.fullyCompleted = 0
              AND p.completed = 1
              AND NOT EXISTS (
                SELECT 1 FROM PaymentTransfers pt
                WHERE pt.paymentID = p.id AND pt.completed = 0
              )
          `);

        await dbTransaction.commit();
      } catch (dbErr) {
        await dbTransaction.rollback();
        throw dbErr;
      }

      return {
        matchedPayments: matchedPayments.map(({ payment, match }) => ({
          paymentName: payment.name,
          accountName: payment.accountName,
          amount: payment.paymentAmount,
          relinked: !!payment.completed, // was already completed, now linked to the replacement transaction
          transactionExternalID: match.externalID,
          transactionName: match.name,
          transactionDate: match.transactionDate,
          transactionPending: !!match.pending
        })),
        matchedTransfers: matchedTransfers.map(({ transfer, match }) => ({
          paymentName: transfer.paymentName,
          accountName: transfer.accountName,
          amount: transfer.transferAmount,
          relinked: !!transfer.completed,
          transactionExternalID: match.externalID,
          transactionName: match.name,
          transactionDate: match.transactionDate,
          transactionPending: !!match.pending
        })),
        stillOpen,
        unlinked
      };
    });

    res.json({ success: true, ...result });

  } catch (err) {
    next(err);
  }
});

// Get the transactions of an account
app.get("/sheets/account/transactions", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets
    const { accountID } = req.query; // Uses externalID (from SimpleFIN or LunchFlow)
    const startDateParam = req.query["start-date"]; // Optional unix timestamp (seconds), same as SimpleFIN

    if (!accountID) {
      return res.status(400).json({
        success: false,
        message: "accountID required as query parameter"
      });
    }

    // Only include transactions on or after start-date when provided
    let startDate = null;
    if (startDateParam !== undefined) {
      if (!/^\d+$/.test(startDateParam)) {
        return res.status(400).json({
          success: false,
          message: "start-date must be a unix timestamp in seconds"
        });
      }
      startDate = new Date(Number(startDateParam) * 1000);
    }

    // When SimpleFIN last updated this account
    const balanceDate = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("accountID", sql.VarChar(50), accountID)
        .query(`
          SELECT balanceDate
          FROM Accounts
          WHERE userID = @userID AND externalID = @accountID
        `);
      return result.recordset[0]?.balanceDate ?? null;
    });

    const transactions = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("accountID", sql.VarChar(50), accountID)
        .input("startDate", sql.DateTimeOffset, startDate)
        .query(`
          SELECT
            t.internalID AS id,
            t.externalID,
            t.accountInternalID AS accountID,
            t.paymentID,
            t.amount,
            t.name,
            t.notes,
            t.transactionDate,
            t.pending,
            t.createdAt,
            t.updatedAt,
            p.name AS paymentName,
            CAST(CASE WHEN p.completed = 1 THEN 1 ELSE 0 END AS BIT) AS paid -- same rule as the app: paid once its payment is completed
          FROM Transactions t
          INNER JOIN Accounts a ON t.accountInternalID = a.internalID
          LEFT JOIN Payments p ON t.paymentID = p.id
          WHERE a.userID = @userID AND a.externalID = @accountID
            AND (@startDate IS NULL OR t.transactionDate >= @startDate)
          ORDER BY t.transactionDate DESC, t.createdAt DESC
        `);
      return result.recordset;
    });

    // Allocations for the transactions above, with the name of the account each split is allocated to
    const allocations = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("accountID", sql.VarChar(50), accountID)
        .input("startDate", sql.DateTimeOffset, startDate)
        .query(`
          SELECT
            ta.transactionInternalID AS transactionID,
            ta.accountInternalID AS accountID,
            alloc.name AS accountName,
            ta.amount
          FROM TransactionAllocations ta
          INNER JOIN Transactions t ON ta.transactionInternalID = t.internalID
          INNER JOIN Accounts a ON t.accountInternalID = a.internalID
          INNER JOIN Accounts alloc ON ta.accountInternalID = alloc.internalID
          WHERE a.userID = @userID AND a.externalID = @accountID
            AND (@startDate IS NULL OR t.transactionDate >= @startDate)
        `);
      return result.recordset;
    });

    // Attach each transaction's allocations (empty array if none)
    const allocationsByTxn = {};
    for (const alloc of allocations) {
      (allocationsByTxn[alloc.transactionID] ??= []).push({
        accountID: alloc.accountID,
        accountName: alloc.accountName,
        amount: alloc.amount
      });
    }
    for (const txn of transactions) {
      txn.allocations = allocationsByTxn[txn.id] || [];
    }

    res.json({
      success: true,
      balanceDate,
      transactions
    });
  } catch (err) {
    next(err);
  }
});

// Get the account balances of all of a user's accounts
app.get("/sheets/accounts/balance-info", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets

    // pendingPayment = sum of this account's Payments (as the paying account) and PaymentTransfers that aren't completed yet
    const accounts = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            a.externalID,
            a.name,
            a.balance,
            a.balanceDate,
            -- Outgoing: payments this account is making that haven't cleared yet
            ISNULL((
              SELECT SUM(p.paymentAmount) FROM Payments p
              WHERE p.paidFromAccountInternalID = a.internalID AND p.completed = 0
            ), 0)
            -- Outgoing: transfers this account is sending to a paying account that haven't cleared yet
            + ISNULL((
              SELECT SUM(pt.transferAmount) FROM PaymentTransfers pt
              WHERE pt.accountInternalID = a.internalID AND pt.completed = 0
            ), 0)
            -- Incoming: transfers into this account's payments that haven't arrived yet (stored negative, so flipped)
            + ISNULL((
              SELECT SUM(-pt.transferAmount) FROM PaymentTransfers pt
              INNER JOIN Payments p ON pt.paymentID = p.id
              WHERE p.paidFromAccountInternalID = a.internalID AND pt.completed = 0
            ), 0) AS pendingPayment
          FROM Accounts a
          WHERE a.userID = @userID AND a.accountSource = 'SimpleFIN'
          ORDER BY a.name
        `);
      return result.recordset;
    });

    res.json({
      success: true,
      accounts
    });

  } catch (err) {
    next(err);
  }
});

// Keep the info from the Chase Transactions sheet and the DB in sync
app.post("/sheets/transactions/sync", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets
    const items = Array.isArray(req.body) ? req.body : req.body?.transactions;

    if (!Array.isArray(items)) {
      return res.status(400).json({ success: false, message: "Body must be an array of transactions" });
    }

    const toCents = (amount) => Math.round(Number(amount) * 100);

    const result = await queryWithRetry(async (pool) => {
      // Runs a query with an IN list of external IDs, in chunks to stay under SQL Server's parameter limit
      async function selectByExternalIDs(ids, buildQuery) {
        const rows = [];
        for (let i = 0; i < ids.length; i += 500) {
          const chunk = ids.slice(i, i + 500);
          const request = pool.request().input("userID", sql.UniqueIdentifier, userID);
          chunk.forEach((id, j) => request.input(`ext${j}`, sql.VarChar(50), id));
          const r = await request.query(buildQuery(chunk.map((_, j) => `@ext${j}`).join(", ")));
          rows.push(...r.recordset);
        }
        return rows;
      }

      // ---------- Load current state ----------
      const externalIDs = [...new Set(items.map(item => item?.externalID).filter(Boolean))];

      const txnRows = await selectByExternalIDs(externalIDs, (inList) => `
        SELECT internalID, externalID, amount, paymentID, notes
        FROM Transactions
        WHERE userID = @userID AND externalID IN (${inList})
      `);
      const txnByExternal = Object.fromEntries(txnRows.map(t => [t.externalID, t]));

      const allocRows = await selectByExternalIDs(externalIDs, (inList) => `
        SELECT ta.transactionInternalID, ta.accountInternalID, ta.amount
        FROM TransactionAllocations ta
        INNER JOIN Transactions t ON ta.transactionInternalID = t.internalID
        WHERE t.userID = @userID AND t.externalID IN (${inList})
      `);
      const allocsByTxn = {};
      for (const a of allocRows) {
        (allocsByTxn[a.transactionInternalID] ??= {})[a.accountInternalID] = toCents(a.amount);
      }

      const accountsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`SELECT internalID, externalID FROM Accounts WHERE userID = @userID AND externalID IS NOT NULL`);
      const accountByExternal = Object.fromEntries(accountsResult.recordset.map(a => [a.externalID, a.internalID]));

      const paymentsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`SELECT id, name, paymentAmount, completed, paidFromAccountInternalID FROM Payments WHERE userID = @userID`);
      const paymentByName = Object.fromEntries(paymentsResult.recordset.map(p => [p.name.trim().toLowerCase(), p]));
      const paymentByID = Object.fromEntries(paymentsResult.recordset.map(p => [p.id, p]));

      // ---------- Work out what changed ----------
      const errors = [];
      const changes = [];
      const affectedPayments = new Set(); // payments whose transactions or allocations changed, recomputed below
      let unchanged = 0;

      const seenExternalIDs = new Set();

      for (const item of items) {
        const txn = txnByExternal[item?.externalID];
        if (!txn) {
          errors.push({ externalID: item?.externalID ?? null, error: "Transaction not found" });
          continue;
        }

        // A repeated row would apply its payment/transfer changes twice, so only the first one is used
        if (seenExternalIDs.has(txn.externalID)) {
          errors.push({ externalID: txn.externalID, error: "Duplicate row, only the first one was applied" });
          continue;
        }
        seenExternalIDs.add(txn.externalID);

        const oldAllocs = allocsByTxn[txn.internalID] || {};

        // New allocations (null/missing = leave as is)
        let newAllocs = oldAllocs;
        if (Array.isArray(item.allocations)) {
          newAllocs = {};
          const unknownAccounts = [];
          for (const alloc of item.allocations) {
            const accountID = accountByExternal[alloc?.accountID];
            if (!accountID) {
              unknownAccounts.push(alloc?.accountID);
              continue;
            }
            newAllocs[accountID] = (newAllocs[accountID] || 0) - Math.abs(toCents(alloc.amount)); // stored negative
          }
          if (unknownAccounts.length > 0) {
            errors.push({ externalID: txn.externalID, error: "Unknown allocation account(s): " + unknownAccounts.join(", ") });
            continue;
          }
        }

        // New payment (null/blank = no payment)
        const paymentName = item.paymentName == null ? "" : String(item.paymentName).trim();
        const newPayment = paymentName ? paymentByName[paymentName.toLowerCase()] : null;
        if (paymentName && !newPayment) {
          errors.push({ externalID: txn.externalID, error: `No payment named "${paymentName}"` });
          continue;
        }
        const newPaymentID = newPayment?.id ?? null;
        const oldPaymentID = txn.paymentID ?? null;

        const allocsChanged =
          Object.keys(oldAllocs).length !== Object.keys(newAllocs).length ||
          Object.entries(newAllocs).some(([accountID, cents]) => oldAllocs[accountID] !== cents);
        const paymentChanged = oldPaymentID !== newPaymentID;
        const notesChanged = typeof item.notes === "string" && item.notes.trim() !== "" && item.notes !== txn.notes;

        if (!allocsChanged && !paymentChanged && !notesChanged) {
          unchanged++;
          continue;
        }

        if (allocsChanged || paymentChanged) {
          if (oldPaymentID) affectedPayments.add(oldPaymentID);
          if (newPaymentID) affectedPayments.add(newPaymentID);
        }

        changes.push({ txn, newAllocs, allocsChanged, newPaymentID, paymentChanged, notesChanged, notes: item.notes });
      }

      // ---------- Save everything atomically ----------
      const paymentsAdjusted = [];
      const dbTransaction = new sql.Transaction(pool);
      await dbTransaction.begin();

      try {
        for (const change of changes) {
          if (change.allocsChanged) {
            await new sql.Request(dbTransaction)
              .input("transactionID", sql.UniqueIdentifier, change.txn.internalID)
              .query(`DELETE FROM TransactionAllocations WHERE transactionInternalID = @transactionID`);

            for (const [accountID, cents] of Object.entries(change.newAllocs)) {
              await new sql.Request(dbTransaction)
                .input("transactionID", sql.UniqueIdentifier, change.txn.internalID)
                .input("accountID", sql.UniqueIdentifier, accountID)
                .input("amount", sql.Decimal(18, 2), cents / 100)
                .query(`
                  INSERT INTO TransactionAllocations (transactionInternalID, accountInternalID, amount, createdAt, updatedAt)
                  VALUES (@transactionID, @accountID, @amount, SYSUTCDATETIME(), SYSUTCDATETIME())
                `);
            }
          }

          if (change.paymentChanged || change.notesChanged) {
            await new sql.Request(dbTransaction)
              .input("transactionID", sql.UniqueIdentifier, change.txn.internalID)
              .input("paymentID", sql.UniqueIdentifier, change.newPaymentID)
              .input("notes", sql.NVarChar(sql.MAX), change.notes)
              .input("setPayment", sql.Bit, change.paymentChanged)
              .input("setNotes", sql.Bit, change.notesChanged)
              .query(`
                UPDATE Transactions
                SET paymentID = CASE WHEN @setPayment = 1 THEN @paymentID ELSE paymentID END,
                    notes = CASE WHEN @setNotes = 1 THEN @notes ELSE notes END,
                    updatedAt = SYSUTCDATETIME()
                WHERE internalID = @transactionID
              `);
          }
        }

        // Recompute each affected payment from what's linked to it now: the total is the sum of its transactions,
        // and each account's transfer is the sum of that account's allocations on those transactions.
        // Completed flags and matched transactions are left as is, even if the amount changes.
        for (const paymentID of affectedPayments) {
          const payment = paymentByID[paymentID];
          const payingAccount = payment.paidFromAccountInternalID ?? null;
          let transfersChanged = false;

          const totalResult = await new sql.Request(dbTransaction)
            .input("paymentID", sql.UniqueIdentifier, paymentID)
            .query(`SELECT ISNULL(SUM(amount), 0) AS total FROM Transactions WHERE paymentID = @paymentID`);
          const newTotalCents = toCents(totalResult.recordset[0].total);
          const oldTotalCents = toCents(payment.paymentAmount);

          if (newTotalCents !== oldTotalCents) {
            await new sql.Request(dbTransaction)
              .input("id", sql.UniqueIdentifier, paymentID)
              .input("amount", sql.Decimal(18, 2), newTotalCents / 100)
              .query(`UPDATE Payments SET paymentAmount = @amount, updatedAt = SYSUTCDATETIME() WHERE id = @id`);
          }

          // Allocations per account, skipping the paying account (Bills doesn't transfer to itself)
          const allocTotalsResult = await new sql.Request(dbTransaction)
            .input("paymentID", sql.UniqueIdentifier, paymentID)
            .input("payingAccount", sql.UniqueIdentifier, payingAccount)
            .query(`
              SELECT ta.accountInternalID, SUM(ta.amount) AS total
              FROM TransactionAllocations ta
              INNER JOIN Transactions t ON ta.transactionInternalID = t.internalID
              WHERE t.paymentID = @paymentID
                AND (@payingAccount IS NULL OR ta.accountInternalID <> @payingAccount)
              GROUP BY ta.accountInternalID
            `);
          const targetByAccount = Object.fromEntries(
            allocTotalsResult.recordset.map(r => [r.accountInternalID, toCents(r.total)])
          );

          const transfersResult = await new sql.Request(dbTransaction)
            .input("paymentID", sql.UniqueIdentifier, paymentID)
            .query(`
              SELECT id, accountInternalID, transferAmount, completed, matchedTransactionID
              FROM PaymentTransfers
              WHERE paymentID = @paymentID
            `);
          const transferByAccount = {};
          for (const transfer of transfersResult.recordset) {
            transferByAccount[transfer.accountInternalID] ??= transfer;
          }

          // Update existing transfers, create missing ones, and remove open, unmatched ones that drop to $0
          for (const accountID of new Set([...Object.keys(targetByAccount), ...Object.keys(transferByAccount)])) {
            const targetCents = targetByAccount[accountID] || 0;
            const transfer = transferByAccount[accountID];

            if (transfer) {
              if (targetCents === 0 && !transfer.completed && !transfer.matchedTransactionID) {
                await new sql.Request(dbTransaction)
                  .input("id", sql.UniqueIdentifier, transfer.id)
                  .query(`DELETE FROM PaymentTransfers WHERE id = @id`);
                transfersChanged = true;
              } else if (targetCents !== toCents(transfer.transferAmount)) {
                await new sql.Request(dbTransaction)
                  .input("id", sql.UniqueIdentifier, transfer.id)
                  .input("amount", sql.Decimal(18, 2), targetCents / 100)
                  .query(`UPDATE PaymentTransfers SET transferAmount = @amount, updatedAt = SYSUTCDATETIME() WHERE id = @id`);
                transfersChanged = true;
              }
            } else if (targetCents !== 0) {
              await new sql.Request(dbTransaction)
                .input("id", sql.UniqueIdentifier, uuidv4())
                .input("amount", sql.Decimal(18, 2), targetCents / 100)
                .input("paymentID", sql.UniqueIdentifier, paymentID)
                .input("accountID", sql.UniqueIdentifier, accountID)
                .query(`
                  INSERT INTO PaymentTransfers (id, transferAmount, paymentID, accountInternalID, createdAt, updatedAt)
                  VALUES (@id, @amount, @paymentID, @accountID, SYSUTCDATETIME(), SYSUTCDATETIME())
                `);
              transfersChanged = true;
            }
          }

          if (newTotalCents !== oldTotalCents || transfersChanged) {
            paymentsAdjusted.push({ paymentName: payment.name, oldAmount: oldTotalCents / 100, newAmount: newTotalCents / 100 });
          }
        }

        await dbTransaction.commit();
      } catch (dbErr) {
        await dbTransaction.rollback();
        throw dbErr;
      }

      return {
        updated: changes.length,
        unchanged,
        paymentsAdjusted,
        errors
      };
    });

    res.json({ success: true, ...result });

  } catch (err) {
    next(err);
  }
});

// Get all of the user's payments and their transfers
app.get("/sheets/payments", verifySheets, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by verifySheets

    const result = await queryWithRetry(async (pool) => {
      // accountName is the account making the payment (Bills)
      const paymentsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT p.name, a.name AS accountName, p.paymentAmount AS amount
          FROM Payments p
          LEFT JOIN Accounts a ON p.paidFromAccountInternalID = a.internalID
          WHERE p.userID = @userID
          ORDER BY p.createdAt ASC
        `);

      // accountName is the account transferring its share to the paying account
      const transfersResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT p.name AS paymentName, a.name AS accountName, pt.transferAmount AS amount
          FROM PaymentTransfers pt
          INNER JOIN Payments p ON pt.paymentID = p.id
          LEFT JOIN Accounts a ON pt.accountInternalID = a.internalID
          WHERE p.userID = @userID
          ORDER BY p.createdAt ASC, a.name ASC
        `);

      return {
        payments: paymentsResult.recordset,
        paymentTransfers: transfersResult.recordset
      };
    });

    res.json(result);

  } catch (err) {
    next(err);
  }
});







// ******* iOS App Specific Endpoints *******













// Register a new user
app.post("/register", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: "Email and password required" });
    }

    // Hash password and generate userID BEFORE the database call
    const hashed = await hashPassword(password);
    const id = uuidv4();

    // Wrap ALL database operations in the retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Check if email already exists
      const existing = await pool.request()
        .input("email", sql.VarChar(255), email)
        .query(`SELECT id FROM Users WHERE email = @email`);

      if (existing.recordset.length > 0) {
        return { emailExists: true };
      }

      // Insert new user into the Azure DB
      await pool.request()
        .input("id", sql.VarChar(50), id)
        .input("email", sql.VarChar(255), email)
        .input("passwordHash", sql.VarChar(255), hashed)
        .query(`
          INSERT INTO Users (
            id, email, passwordHash
          )
          VALUES (@id, @email, @passwordHash)
        `);

      // Fetch the newly created user to return to the client
      const newUserResult = await pool.request()
        .input("id", sql.VarChar(50), id)
        .query(`
          SELECT 
            id, email, createdAt, updatedAt
          FROM Users
          WHERE id = @id
        `);

      return { 
        emailExists: false,
        user: newUserResult.recordset[0]
      };
    });

    // Handle the result OUTSIDE the wrapper
    if (result.emailExists) {
      console.log(`[REGISTER] Registration failed - email already exists: ${email}`);
      return res.status(409).json({
        success: false,
        error: "Email already exists"
      });
    }

    // Generate JWT
    const token = jwt.sign({ id: result.user.id, email: result.user.email }, JWT_SECRET);

    console.log(`[REGISTER] New user registered: ${result.user.id} (${email})`);
    res.json({
      success: true,
      message: `New user registered`,
      token,
      user: result.user
    });

  } catch (err) {
    next(err);
  }
});

// Login an existing user with email/password
app.post("/login", async (req, res, next) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) return res.status(400).json({ success: false, error: "Missing fields" });
    
    // Use the database retry wrapper
    const result = await queryWithRetry(async (pool) => {
      const queryResult = await pool.request()
        .input("email", sql.VarChar(255), email)
        .query(`
          SELECT id, email, simpleFinAccessURLData, lunchFlowAPIKeyData, createdAt, updatedAt, passwordHash
          FROM Users
          WHERE email = @email
        `);

      if (queryResult.recordset.length === 0) {
        return { found: false };
      }

      const user = queryResult.recordset[0];
      const valid = await bcrypt.compare(password, user.passwordHash);

      // Check if credentials are set for each service
      const simpleFINConnected = user.simpleFinAccessURLData != null && user.simpleFinAccessURLData !== '';
      const lunchFlowConnected = user.lunchFlowAPIKeyData != null && user.lunchFlowAPIKeyData !== '';

      // Remove sensitive fields before returning
      delete user.simpleFinAccessURLData;
      delete user.lunchFlowAPIKeyData;
      delete user.passwordHash;

      if (!valid) {
        return { found: true, valid: false };
      }

      // Generate JWT
      const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET);

      return {
        found: true,
        valid: true,
        token,
        user: { ...user, simpleFINConnected, lunchFlowConnected }
      };
    });

    // Handle the result
    if (!result.found) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    if (!result.valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    const responseData = { 
      success: true, 
      token: result.token,
      user: result.user
    };
    
    // console.log("Final response user object:", JSON.stringify(result.user, null, 2));

    return res.json(responseData);

  } catch (err) {
    next(err);
  }
});

// Connect the User's SimpleFin account
app.post("/connect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID, credential } = req.body;
    if (!userID || !credential) return res.status(400).json({
      success: false,
      message: "userID and setup token required",
      accounts: null
    });

    // Decode setup token into claim url
    let claimUrl;
    try {
      claimUrl = Buffer.from(credential, "base64").toString("utf-8");
    } catch {
      return res.status(400).json({
        success: false,
        message: "Invalid setup token format",
        accounts: null
      });
    }

    // Get access url
    let accessUrl;
    try {
      const claimResponse = await axios.post(claimUrl);
      accessUrl = claimResponse.data;

      if (!accessUrl || typeof accessUrl !== "string") {
        throw new Error("Invalid claim response");
      } 
    } catch (err) {
      return res.status(400).json({
        success: false,
        message: "Failed to claim SimpleFIN token (may be expired or already used)",
        accounts: null
      });
    }

    // Fetch user's connected accounts from SimpleFIN
    let accounts;
    try {
      const accountResponse = await axios.get(`${accessUrl}/accounts`);
      accounts = accountResponse.data.accounts;
    } catch (err) {
      return res.status(500).json({
        success: false,
        message: "Failed to fetch accounts from SimpleFIN",
        accounts: null
      });
    }

    // Encrypt the access url before storing it in the database
    const accessEnc = encrypt(accessUrl);

    // Wrap ALL database operations (including transaction) in the retry wrapper
    const userAccounts = await queryWithRetry(async (pool) => {
      // Begin transaction
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      try {
        // Store access URL in Users table
        await new sql.Request(transaction)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("data", sql.VarChar(sql.MAX), accessEnc.data)
          .input("iv", sql.VarChar(32), accessEnc.iv)
          .input("tag", sql.VarChar(32), accessEnc.tag)
          .query(`
            UPDATE Users
            SET simpleFinAccessURLData = @data,
                simpleFinAccessURLIV = @iv,
                simpleFinAccessURLTag = @tag,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @userID
          `);

        // Upsert accounts (MERGE on externalID + userID to support multiple users connecting to the same bank account)
        for (const account of accounts) {
          // Format the balance-date correctly
          const balanceDate = account["balance-date"]
            ? new Date(account["balance-date"] * 1000)
            : null;

          // Extract the account number from the name
          const match = account.name.match(/\((\d+)\)/);
          const accountNumber = match ? match[1] : null;
          const cleanedName = account.name.replace(/\s*\(\d+\)/, "").trim();

          await new sql.Request(transaction)
            .input("externalID", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.org?.name || null)
            .input("accountNumber", sql.Char(6), accountNumber)
            .input("availableBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
            .input("balance", sql.Decimal(18, 2), parseFloat(account["balance"]) || 0)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              MERGE Accounts WITH (HOLDLOCK) AS target
              USING (SELECT @externalID AS externalID, @userID AS userID) AS source
                ON target.externalID = source.externalID AND target.userID = source.userID
              WHEN MATCHED THEN
                UPDATE SET
                  bank = @bank,
                  accountNumber = @accountNumber,
                  availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN
                INSERT (internalID, externalID, userID, name, bank, accountSource, accountNumber, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt)
                VALUES (NEWID(), @externalID, @userID, @name, @bank, 'SimpleFIN', @accountNumber, @availableBalance, @balance, @balanceDate, '-', SYSUTCDATETIME(), SYSUTCDATETIME());
            `);
        }

        await transaction.commit();

        // After all updates, fetch all accounts for this user
        const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`SELECT 
              internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt 
              FROM Accounts WHERE userID = @userID AND accountSource = 'SimpleFIN'`);

        // Return the accounts data
        return result.recordset;

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }
    });

    // Send response OUTSIDE the wrapper
    return res.json({
      success: true,
      message: "SimpleFIN connected successfully",
      accounts: userAccounts
    });

  } catch (err) {
    next(err);
  } 
});

// Disconnect a User's SimpleFIN account
app.post("/disconnect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ 
      success: false,
      message: "userID required"
    });

    // Wrap database operations in retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Query the DB to set the SimpleFIN data to NULL
      const updateResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE Users
          SET simpleFinAccessURLData = NULL,
              simpleFinAccessURLIV = NULL,
              simpleFinAccessURLTag = NULL,
              updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);

      // Delete accounts associated with SimpleFIN
      await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          DELETE FROM Accounts
          WHERE userID = @userID AND accountSource = 'SimpleFIN'
        `);

      return { rowsAffected: updateResult.rowsAffected[0] };
    });
    
    // Check result OUTSIDE the wrapper
    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "User not found or already disconnected"
      });
    }

    res.json({
      success: true,
      message: "SimpleFIN account disconnected"
    });

  } catch (err) {
    next(err);
  } 
});

// Connect the User's Lunch Flow account
app.post("/connect-lunchflow", async (req, res, next) => {
  try {
    // Get id and api key from user
    const { userID, credential } = req.body;
    if (!userID || !credential) return res.status(400).json({ 
      success: false,
      message: "userID and api key required",
      accounts: null
    });

    // Ensure API Key works and get the accounts
    const lunchFlowBaseURL = "https://www.lunchflow.app/api/v1"

    const lfResponse = await fetch(`${lunchFlowBaseURL}/accounts`, {
      method: "GET",
      headers: {
        "x-api-key": credential
      }
    });

    if (!lfResponse.ok) {
      throw new Error(`Lunch Flow API error: ${lfResponse.status}`);
    }

    const body = await lfResponse.json();
    const accounts = body.accounts || body || [];

    // Get the balances of all accounts in parallel
    const balancePromises = accounts.map(account =>
      fetch(`${lunchFlowBaseURL}/accounts/${account.id}/balance`, {
        method: "GET",
        headers: {
          "x-api-key": credential
        }
      })
      .then(res => {
        if (!res.ok) throw new Error(`Balance fetch failed: ${res.status}`);
        return res.json();
      })
      .then(balanceData => ({
        accountId: account.id,
        balanceData
      }))
    );

    const balanceResults = await Promise.all(balancePromises);

    // Add the balance info to each account
    const balanceMap = new Map(
      balanceResults.map(b => [b.accountId, b.balanceData])
    );

    for (const account of accounts) {
      const balanceData = balanceMap.get(account.id);

      // Adjust based on actual API response shape
      const balanceValue =
        balanceData?.balance ??
        balanceData?.current_balance ??
        balanceData?.amount ??
        0;

      account.availableBalance = balanceValue;
      account.balance = balanceValue;
    }

    // Encrypt the api key before storing it in the database
    const accessEnc = encrypt(credential);
    
    const userAccounts = await queryWithRetry(async (pool) => {
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      try {
        // Store encrypted API key
        await new sql.Request(transaction)
          .input("userID", sql.UniqueIdentifier, userID)
          .input("data", sql.VarChar(sql.MAX), accessEnc.data)
          .input("iv", sql.VarChar(32), accessEnc.iv)
          .input("tag", sql.VarChar(32), accessEnc.tag)
          .query(`
            UPDATE Users
            SET lunchFlowAPIKeyData = @data,
                lunchFlowAPIKeyIV = @iv,
                lunchFlowAPIKeyTag = @tag,
                updatedAt = SYSUTCDATETIME()
            WHERE id = @userID
          `);

        // Upsert accounts (MERGE on externalID + userID to support multiple users per bank account)
        for (const account of accounts) {
          const cleanedName = account.name || "Unnamed";

          await new sql.Request(transaction)
            .input("externalID", sql.VarChar(100), String(account.id))
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), cleanedName)
            .input("bank", sql.NVarChar(255), account.institution_name || null)
            .input("availableBalance", sql.Decimal(18, 2), parseFloat(account.availableBalance?.amount ?? account.availableBalance) || 0)
            .input("balance", sql.Decimal(18, 2), parseFloat(account.balance?.amount ?? account.balance) || 0)
            .query(`
              MERGE Accounts WITH (HOLDLOCK) AS target
              USING (SELECT @externalID AS externalID, @userID AS userID) AS source
                ON target.externalID = source.externalID AND target.userID = source.userID
              WHEN MATCHED THEN
                UPDATE SET
                  bank = @bank,
                  availableBalance = @availableBalance,
                  balance = @balance,
                  balanceDate = SYSUTCDATETIME(),
                  updatedAt = SYSUTCDATETIME()
              WHEN NOT MATCHED THEN
                INSERT (internalID, externalID, userID, name, bank, accountSource, availableBalance, balance, balanceDate, accountType, createdAt, updatedAt)
                VALUES (NEWID(), @externalID, @userID, @name, @bank, 'Lunch Flow', @availableBalance, @balance, SYSUTCDATETIME(), '-', SYSUTCDATETIME(), SYSUTCDATETIME());
            `);
        }

        await transaction.commit();

        const result = await pool.request()
          .input("userID", sql.UniqueIdentifier, userID)
          .query(`
            SELECT internalID AS id, externalID, name, bank, accountSource,
                   availableBalance, balance,
                   accountType, createdAt, updatedAt
            FROM Accounts
            WHERE userID = @userID AND accountSource = 'Lunch Flow'
          `);

        return result.recordset;

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }

    });

    return res.json({
      success: true,
      message: "Lunch Flow connected successfully",
      accounts: userAccounts

    });

  } catch (err) {
    next(err);
  } 
});

// Disconnect a User's Lunch Flow account
app.post("/disconnect-lunchflow", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID } = req.body;
    if (!userID) return res.status(400).json({ 
      success: false,
      message: "userID required"
    });

    // Wrap database operations in retry wrapper
    const result = await queryWithRetry(async (pool) => {
      // Query the DB to set the Lunch Flow data to NULL
      const updateResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE Users
          SET lunchFlowAPIKeyData = NULL,
              lunchFlowAPIKeyIV = NULL,
              lunchFlowAPIKeyTag = NULL,
              updatedAt = SYSUTCDATETIME()
          WHERE id = @userID
        `);

      // Delete accounts associated with Lunch Flow
      await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          DELETE FROM Accounts
          WHERE userID = @userID AND accountSource = 'Lunch Flow'
        `);

      return { rowsAffected: updateResult.rowsAffected[0] };
    });
    
    // Check result OUTSIDE the wrapper
    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "User not found or already disconnected"
      });
    }

    res.json({
      success: true,
      message: "SimpleFIN account disconnected"
    });

  } catch (err) {
    next(err);
  } 
});

// Add a new manual account
app.post("/add-manual-account", async (req, res, next) => {
  try {
    const { id, userID, name, balance, bank, accountNumber, availableBalance, accountType, createdAt, updatedAt } = req.body;

    if (!id || !userID || !name || balance === undefined || !createdAt || !updatedAt) {
      return res.status(400).json({
        success: false,
        message: "id, userID, name, balance, createdAt, and updatedAt are required"
      });
    }

    const account = await queryWithRetry(async (pool) => {
      const internalID = id;
      const externalID = id; // No external source for manual accounts
      const resolvedAvailableBalance = availableBalance ?? balance;

      await pool.request()
        .input("internalID", sql.UniqueIdentifier, internalID)
        .input("externalID", sql.VarChar(100), externalID)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), name)
        .input("bank", sql.NVarChar(255), bank || null)
        .input("accountNumber", sql.Char(6), accountNumber || null)
        .input("balance", sql.Decimal(18, 2), balance)
        .input("availableBalance", sql.Decimal(18, 2), resolvedAvailableBalance)
        .input("accountType", sql.VarChar(50), accountType || null)
        .input("createdAt", sql.DateTimeOffset, createdAt)
        .input("updatedAt", sql.DateTimeOffset, updatedAt)
        .query(`
          INSERT INTO Accounts (
            internalID, externalID, userID, name, bank, accountSource,
            accountNumber, availableBalance, balance, balanceDate,
            accountType, createdAt, updatedAt
          )
          VALUES (
            @internalID, @externalID, @userID, @name, @bank, 'Manual',
            @accountNumber, @availableBalance, @balance, @createdAt,
            @accountType, @createdAt, @updatedAt
          )
        `);

      // Record initial balance history
      await pool.request()
        .input("id", sql.UniqueIdentifier, uuidv4())
        .input("accountInternalID", sql.UniqueIdentifier, internalID)
        .input("balance", sql.Decimal(18, 2), balance)
        .input("availableBalance", sql.Decimal(18, 2), resolvedAvailableBalance)
        .input("createdAt", sql.DateTimeOffset, createdAt)
        .input("updatedAt", sql.DateTimeOffset, updatedAt)
        .query(`
          INSERT INTO AccountBalanceHistory (
            id, accountInternalID, availableBalance, balance, balanceDate, createdAt, updatedAt
          )
          VALUES (
            @id, @accountInternalID, @availableBalance, @balance, @createdAt, @createdAt, @updatedAt
          )
        `);

      // Return the newly created account
      const result = await pool.request()
        .input("internalID", sql.UniqueIdentifier, internalID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource,
                 accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE internalID = @internalID
        `);

      return result.recordset[0];
    });

    res.json({
      success: true,
      message: "Manual account created",
      account
    });

  } catch (err) {
    next(err);
  }
})

// Delete a manual account
app.post("/delete-manual-account", async (req, res, next) => {
  try {
    const { userID, accountID } = req.body;

    if (!userID || !accountID) {
      return res.status(400).json({
        success: false,
        message: "userID and accountID are required"
      });
    }

    const result = await queryWithRetry(async (pool) => {
      const deleteResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .input("accountID", sql.UniqueIdentifier, accountID)
        .query(`
          DELETE FROM Accounts
          WHERE internalID = @accountID AND userID = @userID AND accountSource = 'Manual'
        `);

      return { rowsAffected: deleteResult.rowsAffected[0] };
    });

    if (result.rowsAffected === 0) {
      return res.status(404).json({
        success: false,
        message: "Account not found or not a manual account"
      });
    }

    res.json({
      success: true,
      message: "Manual account deleted"
    });

  } catch (err) {
    next(err);
  }
});

// Trigger background sync for the authenticated user: Responds immediately and runs the sync in the background (fire and forget)
app.post("/user/sync-bg", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;

    // Immediately respond to client - don't make them wait
    res.json({
      success: true,
      message: "Sync started in background"
    });

    // Run sync in background (fire and forget)
    setImmediate(async () => {
      try {
        console.log(`[SYNC] Starting background sync for user ${userID}`);

        // Get user's credentials for all connected services
        const user = await queryWithRetry(async (pool) => {
          const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`
              SELECT
                id,
                simpleFinAccessURLData,
                simpleFinAccessURLIV,
                simpleFinAccessURLTag,
                lunchFlowAPIKeyData,
                lunchFlowAPIKeyIV,
                lunchFlowAPIKeyTag
              FROM Users
              WHERE id = @userID
            `);
          return result.recordset[0];
        });

        const hasSimpleFin = user?.simpleFinAccessURLData && user?.simpleFinAccessURLIV && user?.simpleFinAccessURLTag;
        const hasLunchFlow = user?.lunchFlowAPIKeyData && user?.lunchFlowAPIKeyIV && user?.lunchFlowAPIKeyTag;

        if (!hasSimpleFin && !hasLunchFlow) {
          console.log(`[SYNC] User ${userID} has no connected accounts, skipping sync`);
          return;
        }

        await Promise.all([
          hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(),
          hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(),
        ]);

      } catch (err) {
        console.error(`[SYNC] Background sync failed for user ${userID}:`, err.message);
      }
    });

  } catch (err) {
    next(err);
  }
});

// Awaits the SimpleFIN and Lunch Flow sync and responds only when complete
app.post("/user/sync", authRequired, async (req, res, next) => {
  try {
    const userID = req.user?.id ?? req.body.userID;

    console.log(`[SYNC] Starting sync for user ${userID}`);

    // Get user's credentials for all connected services
    const user = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            id,
            simpleFinAccessURLData,
            simpleFinAccessURLIV,
            simpleFinAccessURLTag,
            lunchFlowAPIKeyData,
            lunchFlowAPIKeyIV,
            lunchFlowAPIKeyTag
          FROM Users
          WHERE id = @userID
        `);
      return result.recordset[0];
    });

    // console.log(`[SYNC] User row:`, JSON.stringify({
    //   found: !!user,
    //   hasSimpleFinData: !!user?.simpleFinAccessURLData,
    //   hasSimpleFinIV: !!user?.simpleFinAccessURLIV,
    //   hasSimpleFinTag: !!user?.simpleFinAccessURLTag,
    //   hasLunchFlowData: !!user?.lunchFlowAPIKeyData,
    //   hasLunchFlowIV: !!user?.lunchFlowAPIKeyIV,
    //   hasLunchFlowTag: !!user?.lunchFlowAPIKeyTag,
    // }));

    const hasSimpleFin = user?.simpleFinAccessURLData && user?.simpleFinAccessURLIV && user?.simpleFinAccessURLTag;
    const hasLunchFlow = user?.lunchFlowAPIKeyData && user?.lunchFlowAPIKeyIV && user?.lunchFlowAPIKeyTag;

    if (!hasSimpleFin && !hasLunchFlow) {
      return res.json({
        success: false,
        message: "No connected accounts found for user"
      });
    }

    // Run all available syncs in parallel
    const [simpleFinStats, lunchFlowStats] = await Promise.all([
      hasSimpleFin ? syncSimpleFinDataForUser(user) : Promise.resolve(null),
      hasLunchFlow ? syncLunchFlowDataForUser(user) : Promise.resolve(null),
    ]);

    res.json({
      success: true,
      message: "Sync complete",
      stats: { simpleFin: simpleFinStats, lunchFlow: lunchFlowStats }
    });

  } catch (err) {
    next(err);
  }
});

// Loads all user data - calls on login or app launch
app.get("/user/data", authRequired, async (req, res, next) => {
  try {
    const userID = req.user?.id ?? req.query.userID;

    const userData = await queryWithRetry(async (pool) => {
      // Fetch accounts
      const accountsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE userID = @userID
          ORDER BY createdAt DESC
        `);

      // Fetch transactions
      const transactionsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            t.internalID AS id,
            t.externalID,
            t.accountInternalID AS accountID,
            t.paymentID,
            t.amount,
            t.name,
            t.notes,
            t.transactionDate,
            t.pending,
            t.createdAt,
            t.updatedAt
          FROM Transactions t
          INNER JOIN Accounts a ON t.accountInternalID = a.internalID
          WHERE t.userID = @userID
          ORDER BY t.transactionDate DESC, t.createdAt DESC
        `);

      // Fetch payments
      const paymentsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT id, name, completed, paymentType, creditCardAccountID, createdAt, updatedAt
          FROM Payments
          WHERE userID = @userID
          ORDER BY createdAt ASC
        `);

      // Fetch payment accounts
      const paymentAccountsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            pa.id,
            pa.paymentID,
            pa.accountInternalID,
            pa.paymentAmount,
            pa.isComplete,
            pa.matchedTransactionID,
            pa.createdAt,
            pa.updatedAt
          FROM PaymentAccounts pa
          INNER JOIN Payments p ON pa.paymentID = p.id
          WHERE p.userID = @userID
        `);

      // Fetch all allocations for this user's transactions
      const allocationsResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT
            ta.transactionInternalID AS transactionID,
            ta.accountInternalID AS accountID,
            ta.amount,
            ta.createdAt,
            ta.updatedAt
          FROM TransactionAllocations ta
          INNER JOIN Transactions t ON ta.transactionInternalID = t.internalID
          WHERE t.userID = @userID
        `);

      // Fetch user info (including SimpleFin and Lunch Flow connection status)
      const userResult = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT 
            id, 
            email, 
            CASE 
              WHEN simpleFinAccessURLData IS NOT NULL THEN 1 
              ELSE 0 
            END AS simpleFINConnected,
            CASE 
              WHEN lunchFlowAPIKeyData IS NOT NULL THEN 1 
              ELSE 0 
            END AS lunchFlowConnected,
            createdAt, 
            updatedAt
          FROM Users
          WHERE id = @userID
        `);

      return {
        user: userResult.recordset[0] || null,
        accounts: accountsResult.recordset || [],
        transactions: transactionsResult.recordset || [],
        payments: paymentsResult.recordset || [],
        paymentAccounts: paymentAccountsResult.recordset || [],
        allocations: allocationsResult.recordset || []
      };
    });

    res.json({
      success: true,
      ...userData
    });

  } catch (err) {
    next(err);
  }
});

// Gets all of the User's accounts
app.get("/accounts", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id; // set by authRequired

    const accounts = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          SELECT internalID AS id, externalID, name, bank, accountSource, accountNumber, availableBalance, balance, accountType, balanceDate, createdAt, updatedAt
          FROM Accounts
          WHERE userID = @userID
          ORDER BY createdAt DESC
        `);
      return result.recordset;
    });

    res.json({
      success: true,
      accounts
    });
  } catch (err) {
    next(err);
  }
});

app.post("/update/user", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { newEmail, newPassword } = req.body;

    // Check that info was provided to update
    if (!newEmail && !newPassword) {
      return res.status(400).json({ 
        success: false,
        message: "No user account info to update" 
      });
    }

    // If a password was provided, hash it before sending to DB
    let hashedPassword = null;
    if (newPassword) {
      hashedPassword = await hashPassword(newPassword);
    }

    // Build SET clause to only set the info that was provided
    const setClauses = ["updatedAt = SYSUTCDATETIME()"];
    if (newEmail) setClauses.push("email = @email");
    if (hashedPassword) setClauses.push("passwordHash = @passwordHash");

    const stats = await queryWithRetry(async (pool) => {
      const request = pool.request()
        .input("userID", sql.UniqueIdentifier, userID);
      if (newEmail) request.input("email", sql.VarChar(255), newEmail);
      if (hashedPassword) request.input("passwordHash", sql.VarChar(255), hashedPassword);
      const result = await request.query(`
          UPDATE Users
          SET ${setClauses.join(", ")}
          OUTPUT INSERTED.updatedAt
          WHERE id = @userID
        `);
      return result.recordset;
    });

    res.json({
      success: true,
      message: "User account info updated successfully",
      updatedAt: stats[0]?.updatedAt ?? null
    });
  } catch (err) {
    next(err);
  }
});

app.post("/update/accounts", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const clientAccounts = req.body.accounts;

    if (!Array.isArray(clientAccounts) || clientAccounts.length === 0) {
      return res.status(400).json({ success: false, message: "accounts array is required" });
    }

    const stats = await queryWithRetry(async (pool) => {
      const transaction = new sql.Transaction(pool);
      await transaction.begin();

      let accountsUpdated = 0;

      try {
        for (const account of clientAccounts) {
          await new sql.Request(transaction)
            .input("accountInternalID", sql.UniqueIdentifier, account.id)
            .input("userId", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), account.name)
            .input("accountType", sql.VarChar(50), account.accountType)
            .query(`
              UPDATE Accounts
              SET name = @name,
                  accountType = @accountType,
                  updatedAt = SYSUTCDATETIME()
              WHERE internalID = @accountInternalID AND userID = @userId
            `);

          accountsUpdated++;
        }

        await transaction.commit();

        return accountsUpdated

      } catch (dbErr) {
        await transaction.rollback();
        throw dbErr;
      }
    });

    return res.json({
      success: true,
      message: "Accounts updated successfully",
      accountsUpdated: stats
    });
  } catch (err) {
    next(err);
  }
});

// Save (replace) allocations for a transaction
app.post("/transaction/allocations", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { transactionID, allocations } = req.body;

    if (!transactionID || !Array.isArray(allocations)) {
      return res.status(400).json({
        success: false,
        message: "transactionID and allocations array are required"
      });
    }

    // Verify the transaction belongs to this user before opening a DB transaction
    const txnExists = await queryWithRetry(async (pool) => {
      const result = await pool.request()
        .input("transactionID", sql.UniqueIdentifier, transactionID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`SELECT internalID FROM Transactions WHERE internalID = @transactionID AND userID = @userID`);
      return result.recordset.length > 0;
    });

    if (!txnExists) {
      return res.status(404).json({ success: false, message: "Transaction not found" });
    }

    // Delete existing allocations and insert new ones atomically
    await queryWithRetry(async (pool) => {
      const dbTransaction = new sql.Transaction(pool);
      await dbTransaction.begin();

      try {
        // Delete all existing allocations for this transaction
        await new sql.Request(dbTransaction)
          .input("transactionID", sql.UniqueIdentifier, transactionID)
          .query(`DELETE FROM TransactionAllocations WHERE transactionInternalID = @transactionID`);

        // Insert each new allocation
        for (const entry of allocations) {
          if (!entry.accountID || entry.amount == null) continue;

          await new sql.Request(dbTransaction)
            .input("transactionID", sql.UniqueIdentifier, transactionID)
            .input("accountID", sql.UniqueIdentifier, entry.accountID)
            .input("amount", sql.Decimal(18, 2), -Math.abs(parseFloat(entry.amount)))
            .query(`
              INSERT INTO TransactionAllocations (transactionInternalID, accountInternalID, amount, createdAt, updatedAt)
              VALUES (@transactionID, @accountID, @amount, SYSUTCDATETIME(), SYSUTCDATETIME())
            `);
        }

        await dbTransaction.commit();
      } catch (dbErr) {
        await dbTransaction.rollback();
        throw dbErr;
      }
    });

    res.json({ success: true, message: "Allocations saved" });

  } catch (err) {
    next(err);
  }
});

// Update the note on a transaction
app.post("/transaction/notes", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { transactionID, notes } = req.body;

    if (!transactionID || notes == null) {
      return res.status(400).json({ success: false, message: "transactionID and notes are required" });
    }

    const result = await queryWithRetry(async (pool) => {
      return pool.request()
        .input("transactionID", sql.UniqueIdentifier, transactionID)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("notes", sql.NVarChar(sql.MAX), notes)
        .query(`
          UPDATE Transactions
          SET notes = @notes, updatedAt = SYSUTCDATETIME()
          WHERE internalID = @transactionID AND userID = @userID
        `);
    });

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({ success: false, message: "Transaction not found" });
    }

    res.json({ success: true, message: "Note updated" });

  } catch (err) {
    next(err);
  }
});

app.post("/transaction/create", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { id, accountID, name, amount, notes, transactionDate, createdAt, updatedAt, accountUpdatedAt } = req.body;

    if (!id || !accountID || !name || amount === undefined || !transactionDate || !createdAt || !updatedAt || !accountUpdatedAt) {
      return res.status(400).json({ success: false, message: "id, accountID, name, amount, transactionDate, createdAt, updatedAt, and accountUpdatedAt are required" });
    }

    const txnDate = new Date(transactionDate);
    if (isNaN(txnDate.getTime())) {
      return res.status(400).json({ success: false, message: "Invalid transactionDate" });
    }

    const result = await queryWithRetry(async (pool) => {
      const insertResult = await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("accountID", sql.UniqueIdentifier, accountID)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar, name)
        .input("amount", sql.Decimal(18, 2), amount)
        .input("notes", sql.NVarChar, notes || "")
        .input("transactionDate", sql.DateTimeOffset, txnDate)
        .input("createdAt", sql.DateTimeOffset, new Date(createdAt))
        .input("updatedAt", sql.DateTimeOffset, new Date(updatedAt))
        .query(`
          INSERT INTO Transactions (
            internalID, externalID, accountInternalID, userID, amount, name, notes,
            transactionDate, pending, createdAt, updatedAt
          )
          VALUES (
            @id, @id, @accountID, @userID, @amount, @name, @notes,
            @transactionDate, 0, @createdAt, @updatedAt
          )
        `);

      // Update manual account balance
      await pool.request()
        .input("accountID", sql.UniqueIdentifier, accountID)
        .input("amount", sql.Decimal(18, 2), amount)
        .input("accountUpdatedAt", sql.DateTimeOffset, new Date(accountUpdatedAt))
        .query(`
          UPDATE Accounts
          SET balance = balance + @amount,
              availableBalance = availableBalance + @amount,
              updatedAt = @accountUpdatedAt
          WHERE internalID = @accountID AND accountSource = 'Manual'
        `);

      return insertResult;
    });

    if (result.rowsAffected[0] === 0) {
      return res.status(500).json({ success: false, message: "Failed to insert transaction" });
    }

    res.json({ success: true, message: "Transaction created" });
  } catch (err) {
    next(err);
  }
});

app.post("/transaction/delete", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { id, accountUpdatedAt } = req.body;

    if (!id || !accountUpdatedAt) {
      return res.status(400).json({ success: false, message: "id and accountUpdatedAt are required" });
    }

    const result = await queryWithRetry(async (pool) => {
      // Fetch the transaction first so we can reverse its balance effect
      const txnResult = await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`SELECT accountInternalID, amount FROM Transactions WHERE internalID = @id AND userID = @userID`);

      if (txnResult.recordset.length === 0) return { rowsAffected: 0 };

      const { accountInternalID, amount } = txnResult.recordset[0];

      const deleteResult = await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`DELETE FROM Transactions WHERE internalID = @id AND userID = @userID`);

      // Reverse the transaction's effect on the manual account balance
      await pool.request()
        .input("accountID", sql.UniqueIdentifier, accountInternalID)
        .input("amount", sql.Decimal(18, 2), amount)
        .input("accountUpdatedAt", sql.DateTimeOffset, new Date(accountUpdatedAt))
        .query(`
          UPDATE Accounts
          SET balance = balance - @amount,
              availableBalance = availableBalance - @amount,
              updatedAt = @accountUpdatedAt
          WHERE internalID = @accountID AND accountSource = 'Manual'
        `);

      return deleteResult;
    });

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({ success: false, message: "Transaction not found" });
    }

    res.json({ success: true, message: "Transaction deleted" });
  } catch (err) {
    next(err);
  }
});

app.post("/transaction/payment", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { transactionID, paymentID } = req.body;

    if (!transactionID) {
      return res.status(400).json({ success: false, message: "transactionID is required" });
    }

    const result = await queryWithRetry(async (pool) => {
      return pool.request()
        .input("transactionID", sql.UniqueIdentifier, transactionID)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("paymentID", sql.UniqueIdentifier, paymentID || null)
        .query(`
          UPDATE Transactions
          SET paymentID = @paymentID, updatedAt = SYSUTCDATETIME()
          WHERE internalID = @transactionID AND userID = @userID
        `);
    });

    if (result.rowsAffected[0] === 0) {
      return res.status(404).json({ success: false, message: "Transaction not found" });
    }

    res.json({ success: true, message: "Payment updated" });

  } catch (err) {
    next(err);
  }
});

app.post("/payment/create", authRequired, async (req, res, next) => {
  try {
    const { id, userID, name, paymentType, creditCardAccountID, transactionIDs, paymentAccounts, createdAt, updatedAt } = req.body;

    if (!id || !userID || !name || !paymentType || !creditCardAccountID || !createdAt || !updatedAt) {
      return res.status(400).json({
        success: false,
        message: "id, userID, name, paymentType, creditCardAccountID, createdAt, and updatedAt are all required"
      });
    }

    if (!Array.isArray(paymentAccounts) || paymentAccounts.length === 0) {
      return res.status(400).json({
        success: false,
        message: "paymentAccounts array is required and must not be empty"
      });
    }

    await queryWithRetry(async (pool) => {
      // Create the Payment row
      await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("userID", sql.UniqueIdentifier, userID)
        .input("name", sql.NVarChar(255), name)
        .input("paymentType", sql.NVarChar(20), paymentType)
        .input("creditCardAccountID", sql.UniqueIdentifier, creditCardAccountID)
        .input("createdAt", sql.DateTimeOffset, createdAt)
        .input("updatedAt", sql.DateTimeOffset, updatedAt)
        .query(`
          INSERT INTO Payments (
            id, userID, name, paymentType, creditCardAccountID, createdAt, updatedAt
          )
          VALUES (
            @id, @userID, @name, @paymentType, @creditCardAccountID, @createdAt, @updatedAt
          )
        `);

      // Insert one PaymentAccount row per debit account
      // Each paymentAccount: { id, accountInternalID, paymentAmount }
      for (const pa of paymentAccounts) {
        await pool.request()
          .input("paID", sql.UniqueIdentifier, pa.id)
          .input("paymentID", sql.UniqueIdentifier, id)
          .input("accountInternalID", sql.UniqueIdentifier, pa.accountInternalID)
          .input("paymentAmount", sql.Decimal(18, 2), pa.paymentAmount)
          .query(`
            INSERT INTO PaymentAccounts (id, paymentID, accountInternalID, paymentAmount)
            VALUES (@paID, @paymentID, @accountInternalID, @paymentAmount)
          `);
      }

      // Link each transaction to this payment
      const txnIDs = Array.isArray(transactionIDs) ? transactionIDs : [];
      for (const transactionID of txnIDs) {
        await pool.request()
          .input("paymentID", sql.UniqueIdentifier, id)
          .input("transactionID", sql.UniqueIdentifier, transactionID)
          .query(`
            UPDATE Transactions
            SET paymentID = @paymentID, updatedAt = SYSUTCDATETIME()
            WHERE internalID = @transactionID
          `);
      }
    });

    res.json({ success: true, message: "Payment created" });

  } catch (err) {
    next(err);
  }
});

app.post("/payment/delete", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { id } = req.body;

    if (!id) {
      return res.status(400).json({ success: false, message: "id is required" });
    }

    const result = await queryWithRetry(async (pool) => {
      // Unlink any transactions that belong to this payment
      await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE Transactions
          SET paymentID = NULL, updatedAt = SYSUTCDATETIME()
          WHERE paymentID = @id AND userID = @userID
        `);

      const deleteResult = await pool.request()
        .input("id", sql.UniqueIdentifier, id)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          DELETE FROM Payments
          WHERE id = @id AND userID = @userID
        `);

      return { rowsAffected: deleteResult.rowsAffected[0] };
    });

    if (result.rowsAffected === 0) {
      return res.status(404).json({ success: false, message: "Payment not found or cannot be deleted" });
    }

    res.json({ success: true, message: "Payment deleted" });

  } catch (err) {
    next(err);
  }
});

// Manually mark a single PaymentAccount as complete.
// Also flips Payment.completed = 1 if all PaymentAccounts for that payment are now complete.
app.post("/payment/account/complete", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { paymentAccountID } = req.body;

    if (!paymentAccountID) {
      return res.status(400).json({ success: false, message: "paymentAccountID is required" });
    }

    await queryWithRetry(async (pool) => {
      // Mark the PaymentAccount complete
      const updateResult = await pool.request()
        .input("paymentAccountID", sql.UniqueIdentifier, paymentAccountID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE pa
          SET pa.isComplete = 1, pa.updatedAt = SYSUTCDATETIME()
          FROM PaymentAccounts pa
          INNER JOIN Payments p ON pa.paymentID = p.id
          WHERE pa.id = @paymentAccountID AND p.userID = @userID
        `);

      if (updateResult.rowsAffected[0] === 0) {
        throw Object.assign(new Error("PaymentAccount not found"), { statusCode: 404 });
      }

      // Flip Payment.completed if all its PaymentAccounts are now complete
      await pool.request()
        .input("paymentAccountID", sql.UniqueIdentifier, paymentAccountID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE p
          SET p.completed = 1, p.updatedAt = SYSUTCDATETIME()
          FROM Payments p
          INNER JOIN PaymentAccounts pa ON pa.paymentID = p.id
          WHERE pa.id = @paymentAccountID
            AND p.userID = @userID
            AND NOT EXISTS (
              SELECT 1 FROM PaymentAccounts pa2
              WHERE pa2.paymentID = p.id AND pa2.isComplete = 0
            )
        `);
    });

    res.json({ success: true, message: "Payment account marked complete" });

  } catch (err) {
    if (err.statusCode === 404) {
      return res.status(404).json({ success: false, message: err.message });
    }
    next(err);
  }
});

// Link a cleared transaction to a PaymentAccount and mark it complete.
// Also flips Payment.completed = 1 if all PaymentAccounts for that payment are now complete.
app.post("/payment/account/match", authRequired, async (req, res, next) => {
  try {
    const userID = req.user.id;
    const { paymentAccountID, transactionID } = req.body;

    if (!paymentAccountID || !transactionID) {
      return res.status(400).json({ success: false, message: "paymentAccountID and transactionID are required" });
    }

    await queryWithRetry(async (pool) => {
      // Link the transaction and mark complete
      const updateResult = await pool.request()
        .input("paymentAccountID", sql.UniqueIdentifier, paymentAccountID)
        .input("transactionID", sql.UniqueIdentifier, transactionID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE pa
          SET pa.matchedTransactionID = @transactionID,
              pa.isComplete = 1,
              pa.updatedAt = SYSUTCDATETIME()
          FROM PaymentAccounts pa
          INNER JOIN Payments p ON pa.paymentID = p.id
          WHERE pa.id = @paymentAccountID AND p.userID = @userID
        `);

      if (updateResult.rowsAffected[0] === 0) {
        throw Object.assign(new Error("PaymentAccount not found"), { statusCode: 404 });
      }

      // Flip Payment.completed if all its PaymentAccounts are now complete
      await pool.request()
        .input("paymentAccountID", sql.UniqueIdentifier, paymentAccountID)
        .input("userID", sql.UniqueIdentifier, userID)
        .query(`
          UPDATE p
          SET p.completed = 1, p.updatedAt = SYSUTCDATETIME()
          FROM Payments p
          INNER JOIN PaymentAccounts pa ON pa.paymentID = p.id
          WHERE pa.id = @paymentAccountID
            AND p.userID = @userID
            AND NOT EXISTS (
              SELECT 1 FROM PaymentAccounts pa2
              WHERE pa2.paymentID = p.id AND pa2.isComplete = 0
            )
        `);
    });

    res.json({ success: true, message: "Payment account matched and marked complete" });

  } catch (err) {
    if (err.statusCode === 404) {
      return res.status(404).json({ success: false, message: err.message });
    }
    next(err);
  }
});

/*****************************************
 * Global Error Handling
 *****************************************/
app.use((err, req, res, next) => {
  console.error('Error occurred:', err);

  // Check if it's a database connection error
  if (err.code === 'ETIMEOUT' || err.code === 'ESOCKET' || 
      (err.name === 'ConnectionError' && err.message.includes('Failed to connect'))) {
    return res.status(503).json({
      success: false,
      message: "Could not connect to DB, please try again in a moment",
      error: "DatabaseUnavailable"
    });
  }

  // Other SQL/Database errors
  if (err.name === 'ConnectionError' || err.name === 'RequestError') {
    return res.status(500).json({
      success: false,
      message: "Database error occurred",
      error: "DatabaseError"
    });
  }

  // Generic server error
  res.status(500).json({
    success: false,
    message: err.message || "Internal server error",
    error: "ServerError"
  });
});
