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

function verifyCron(req, res, next) {
  const secret = req.header("x-cron-secret");

  if (!secret || secret !== process.env.CRON_SECRET) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  next();
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

// Wrapper for any SQL Query to the DB to handle sleeping DB issues
async function queryWithRetry(callback, options = {}) {
  const maxRetries = options.maxRetries || 3;
  const retryDelay = options.retryDelay || 5000; // 5 seconds
  const trackAttempts = options.trackAttempts || false; // New option to return attempt count
  
  let lastError;
  
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      console.log(`[DB] Connection attempt ${attempt}/${maxRetries}`);
      
      // Try to connect to the database
      const pool = await sql.connect(azureConfig);
      
      console.log(`[DB] Connected successfully on attempt ${attempt}`);
      
      // Execute the callback with the connected pool
      const result = await callback(pool);
      
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
        console.log(`[DB] ⚠️  Connection failed (attempt ${attempt}/${maxRetries}): ${err.message}`);
        console.log(`[DB] 🔄 Retrying in ${retryDelay/1000} seconds...`);
        
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




/*****************************************
 * API Endpoints
 *****************************************/
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
        retryDelay: 3000, // 3 seconds for health checks
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
})

// Internal call from GitHub action to keep DB up to date
app.post("/internal/sync-simplefin-data", verifyCron, async (req, res, next) => {
  res.json({
    success: true,
    message: "Temporary response"
  });
});

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
    const tgid = uuidv4();

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

      // Create a "Manual" transfer group by default for all users
      await pool.request()
        .input("tgid", sql.VarChar(50), tgid)
        .input("userID", sql.VarChar(50), id)
        .input("name", sql.VarChar(255), "Manual")
        .query(`
          INSERT INTO TransferGroups (id, userID, name)
          VALUES (@tgid, @userID, @name)
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
      return res.status(409).json({ 
        success: false, 
        error: "Email already exists" 
      });
    }

    // Generate JWT
    const token = jwt.sign({ id: result.user.id, email: result.user.email }, JWT_SECRET);

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
          SELECT id, email, simpleFinAccessURLData, createdAt, updatedAt, passwordHash
          FROM Users
          WHERE email = @email
        `);

      if (queryResult.recordset.length === 0) {
        return { found: false };
      }

      const user = queryResult.recordset[0];
      const valid = await bcrypt.compare(password, user.passwordHash);

      // Remove sensitive fields before returning
      const simpleFinCredentialsSet = !!user.simpleFinAccessURLData;
      delete user.simpleFinAccessURLData;
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
        user: { ...user, simpleFinCredentialsSet }
      };
    });

    // Handle the result
    if (!result.found) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    if (!result.valid) {
      return res.json({ success: false, message: "Invalid email and password" });
    }

    return res.json({ 
      success: true, 
      token: result.token,
      user: result.user
    });

  } catch (err) {
    next(err);
  }
});

// Connect the User's SimpleFin account
app.post("/connect-simplefin", async (req, res, next) => {
  try {
    // Get id and token from user
    const { userID, setupToken } = req.body;
    if (!userID || !setupToken) return res.status(400).json({ 
      success: false,
      message: "userID and setup token required",
      accounts: null
    });

    // Decode setup token into claim url
    let claimUrl;
    try {
      claimUrl = Buffer.from(setupToken, "base64").toString("utf-8");
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

        // Upsert accounts
        for (const account of accounts) {
          // Format the balance-date correctly
          const balanceDate = account["balance-date"]
            ? new Date(account["balance-date"] * 1000)
            : null;

          await new sql.Request(transaction)
            .input("id", sql.VarChar(100), account.id)
            .input("userID", sql.UniqueIdentifier, userID)
            .input("name", sql.NVarChar(255), account.name)
            .input("accountBalance", sql.Decimal(18, 2), parseFloat(account["available-balance"]) || 0)
            .input("balanceDate", sql.DateTimeOffset, balanceDate)
            .query(`
              -- Update the account if it already exists
              UPDATE Accounts
              SET name = @name,
                  accountBalance = @accountBalance,
                  balanceDate = @balanceDate,
                  updatedAt = SYSUTCDATETIME()
              WHERE id = @id AND userID = @userID;

              -- If the account did no exist, insert new account with type 'N/A'
              IF @@ROWCOUNT = 0
              BEGIN
                INSERT INTO Accounts (
                  id, userID, name, accountBalance, balanceDate,
                  accountType, createdAt, updatedAt
                )
                VALUES (
                  @id, @userID, @name, @accountBalance, @balanceDate,
                  'N/A', SYSUTCDATETIME(), SYSUTCDATETIME()
                )
              END
            `);
        }

        await transaction.commit();

        // After all updates, fetch all accounts for this user
        const result = await pool.request()
            .input("userID", sql.UniqueIdentifier, userID)
            .query(`SELECT id, name, accountBalance, accountType, balanceDate, createdAt FROM Accounts WHERE userID = @userID`);

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
      message: "Database is starting up, please try again in a moment",
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
