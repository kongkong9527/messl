function [p_lr_iwt params hardMasks] = messlMultichannel(X, tau, I, varargin)

% [p_lr_iwt params hardMasks] = messlMultichannel(X, tau, I, [name1, value1] ...)
%
% Perform MESSL algorithm (including ILD, frequency-dependent ITD,
% source prior GMMs) on a multichannel mixture of I spatially separated
% sources.
%
% X is the multichannel mixture in the frequency domain, an FxTxC matrix.  TAU is
% the grid of times over which to evaluate the probability of the
% various samples.  The three "mode" options behave in similar
% ways, but control different variables.  A mode of 0 indicates
% that that feature should not be used.  A positive mode specifies
% the number of bands to break the frequency axis into, a separate
% parameter being used for each one.  A negative number specifies
% how many frequencies to use per band.
%
% The returned arguments are the probability of each point in the
% spectrogram coming from each source and the parameters for each
% of the source models.
% 
% Valid named arguments are:
%
% ::Multichannel::
% refMic          (0) reference mic if positive (N-1 pairs), otherwise use all N*(N-1)/2 pairs
%
% ::Initialization::
% tauPosInit     ([]) init source pos's (in samples), otherwise from xcorr
% pTauIInit      ([]) initial p(tau|i) distributions, gaussians
%                     around tauPosInit if not specified here
% sigmaInit      ([]) initial stddev of IPD residual
% xiInit         ([]) initial IPD mean
% ildInit         (0) WxI, initial mean ILD, in dB, can be matrix for freq dep
% ildStdInit     (10) WxI, initial std ILD, in dB, can be matrix for freq dep
% maskInit       ([]) to specify a permanent prior on the WxTxI mask
% maskHold        (0) number of iterations to hold the prior mask
%
% ::Mode selection::
% modes          ([]) vector of [ipd ild sp xi sigma dct] modes all together
% ipdMode         (1) 0 => no IPD, 1 => use IPD as defined by
%                     xiMode and sigmaMode
% ildMode        (-1) 0 => no ILD, 1 => freq indep, -1 => freq dep
%                    -2
% spMode          (0) 0 => no SP, 1 => model L and R responses separately,
%                    -1 => model L+R
% xiMode         (-1) 0 => ipd mean=0, 1 => freq indep, -1 => freq dep
% sigmaMode      (-1) 0 => varies by source, 1 => varies by src,tau,
%                    -1 => varies by src,tau,freq
% dctMode         (0) 0 => use canonical basis for ILD and SP parameters,
%                     n => use n DCT bases for ILD and SP params
%
% ::Extended features::
% garbageSrc      (0) add a garbage source with special init and updates
% sourcePriors   ([]) list of I GMM structures.  Not used if empty
% reliability    ([]) relative weights for each spectrogram point
%                     for use in parameter estimation
% ildPriorPrec    (0) precision (inverse variance) of ILD prior
% sr          (16000) sampling rate, only used by ILD prior
% mrfLbpIter      (8) number of iterations for MRF loopy belief propagation
%
% ::Nuts and bolts::
% vis             (0) plot informational displays
% nfft         (1024) window size of FFT
% Nrep           (16) number of EM iterations

[tauPosInit, pTauIInit, ildInit, ildStdInit, maskInit, garbageSrc, ...
 ipdMode, ildMode, xiMode, sigmaMode, dctMode, spMode, nfft, ...
 vis, Nrep, modes, sigmaInit, xiInit, sourcePriors, maskHold, ...
 reliability, ildPriorPrec, sr, mrfHardCompatExp, mrfCompatFile ...
 mrfCompatExpSched fixIPriors refMic mrfLbpIter useConsistentTdoa] = ...
    process_options(varargin, 'tauPosInit', [], 'pTauIInit', [], ...
    'ildInit', 0, 'ildStdInit', 10, 'maskInit', [], ...
    'garbageSrc', 0, 'ipdMode', 1, 'ildMode', -1, 'xiMode', -1, ...
    'sigmaMode', -1, 'dctMode', 0, 'spMode', 0, 'nfft', 1024, 'vis', 0, ...
    'Nrep', 16, 'modes', [], 'sigmaInit', [], 'xiInit', [], ...
    'sourcePriors', [], 'maskHold', 0, 'reliability', [], ...
    'ildPriorPrec', 0, 'sr', 16000, 'mrfHardCompatExp', 0, ...
    'mrfCompatFile', '', 'mrfCompatExpSched', [0 0 0 0 .02 .02 .02 .02 .05], ...
    'fixIPriors', 0, 'refMic', 0, 'mrfLbpIter', 8, 'useConsistentTdoa', 0);

if ~isempty(modes)
  ipdMode   = modes(1);
  ildMode   = modes(2);
  spMode    = modes(3);
  xiMode    = modes(4);
  sigmaMode = modes(5);
  dctMode   = modes(6);
end

if spMode && isempty(sourcePriors)
  spMode = 0;
  warning('spMode set to 1, but ''sourcePriors'' option was not set.');
end

Ch = size(X, 3);
if refMic > 0
    channelPairs = [refMic*ones(Ch-1,1) setdiff((1:Ch)', refMic)];
    overcountRescale = 1;
else
    % TODO: this should probably be (Ch - 1) in the numerator
    channelPairs = nchoosek(1:Ch, 2);
    overcountRescale = Ch / (size(channelPairs,1) - 1);
end
Np = size(channelPairs,1);

if isempty(maskInit)
    % Run messl on each pair for several iterations to initialize parameters
    for c = 1:Np
        cp = channelPairs(c,:);
        fprintf('Channels: %d %d\n', cp(1), cp(2));
        [p_lr_iwt params(c)] = messl(X(:,:,cp), tau, I, varargin{:}, 'Nrep', 4, 'modes', [1 1 0 1 1 0]);
        masks(:,:,:,c) = squeeze(p_lr_iwt(1,:,:,:));
    end
    
    % Permute sources to match across mic pairs.  Treat each TF point as a
    % multinomial RV across sources, find permutation with minimum total
    % symmetrized KL divergence to reference (first mic pair).
    % TODO: find best reference mic pair.
    targetMasks = masks(:,:,1:I,1);
    allOrds = perms(1:I);
    for c = 1:size(masks,4)
        for oi = 1:size(allOrds,1)
            permMasks = masks(:,:,allOrds(oi,:),c);
            kldiv(oi) = (targetMasks(:) - permMasks(:))' * log(targetMasks(:) ./ permMasks(:));
        end
        [~,oi] = min(kldiv);
        masks(:,:,1:I,c) = masks(:,:,allOrds(oi,:),c);
        targetMasks = mean(masks(:,:,1:I,1:c), 4);
        if garbageSrc
            ord = [allOrds(oi,:) I+1];
        else
            ord = allOrds(oi,:);
        end
        pTauIInit(:,:,c) = params(c).p_tauI(ord,:);
    end
else
    pTauIInit = ones(I+garbageSrc,length(tau),Np);
end
% % Hard-coded for test example...
%tauPosInit = [-23; 0; 22];

if (Np > Ch) && useConsistentTdoa
    % Compute global TDOA at each mic, re-derive pairwise ITDs
    perPairTdoa = tau(squeeze(argmax(pTauIInit,2)))';   % posterior mode
    % perPairTdoa = squeeze(sum(bsxfun(@times, tau, pTauIInit), 2) ./ sum(pTauIInit,2))';  % posterior mean
    [perMicTdoa tauPosInit] = perMicTdoaLs(perPairTdoa(:,1:end-garbageSrc), channelPairs);
else
    tauPosInit = [];
end

fprintf('Done init, starting multi-channel MESSL...\n')

% Start actual Multi-channel MESSL using those alignments.  Re-initialize
% parameters.
for c = 1:Np
    cp = channelPairs(c,:);
    [~,~,~,W,T,~,L,R] = messlObsDerive(X(:,:,cp), tau, nfft);
    
    % Initialize the probability distributions and other parameters
    if isempty(tauPosInit)
        [ipdParams(c) itds] = messlIpdInit(I, W, Nrep, tau, sr, X, [], pTauIInit(:,:,c), ...
            sigmaInit, xiInit, ipdMode, xiMode, sigmaMode, ...
            garbageSrc, vis, fixIPriors);
    else
        [ipdParams(c) itds] = messlIpdInit(I, W, Nrep, tau, sr, X, tauPosInit(c,:), [], ...
            sigmaInit, xiInit, ipdMode, xiMode, sigmaMode, ...
            garbageSrc, vis, fixIPriors);
    end
    clear lr
    %FIXME
    ildParams(c) = messlIldInit(I, W, sr, Nrep, ildInit, ildStdInit, ...
        ildPriorPrec*T/100, ildMode, itds, ...
        false&dctMode,  garbageSrc);
    %dctMode,  garbageSrc);
    [spParams(c) C] = messlSpInit(I, W, L, R, sourcePriors, ildStdInit, dctMode, ...
        spMode, garbageSrc);
end

mrfCompatPot = messlMrfLoadCompat(mrfCompatFile, I, garbageSrc);
                  
% The rest of the code should act like the garbage source is like
% any other source, except for the M step, which has to know about
% it so it doesn't update it
I = I + garbageSrc;

% Inialize the mask prior
logMaskPrior = 0;
if ~isempty(maskInit)
  logMaskPrior = single(log(maskInit));
end

% Keep track of the total log likelihood
ll = [];

logMultichannelPosteriors = zeros(W, T, I, Np);

% Start EM
for rep=1:Nrep
    fprintf('ll(%02d) = ', rep);
    
    for useCombinedPost = [0 1]
        for c = 1:Np
            cp = channelPairs(c,:);
            [A,angE,~,W,T,Nt,L,R] = messlObsDerive(X(:,:,cp), tau, nfft);
            
            clear nu*
            
            % Turn on SP mode if we've reached the appropriate iteration.
            if (rep == spParams(c).spStartRep) && (useCombinedPost == 0)
                spParams(c).spMode = spParams(c).origSpMode;
                
                % The GMMs could have been passed to this function in an
                % arbitrary order.  Fix this by permuting the gmms so that they
                % match the binaural sources.
                if spParams(c).spMode && ~isfield(spParams(c), 'ev_params')
                    maskBin = maskIpd .* maskIld;
                    maskBin = maskBin ./ repmat(sum(maskBin,3), [1 1 I]);
                    spParams(c).sourcePriors(1:I-garbageSrc) = messlSpPermuteGmms( ...
                        spParams(c).sourcePriors,  L, R, maskBin, I-garbageSrc);
                end
            end
            
            
            %%%% E step: calculate nu matrix
            lpIpd = 0;  lpIld = 0;  lpSp = 0;
            if ipdParams(c).ipdMode
                lpIpd = messlIpdLogLikelihood(W,T,I,Nt,C,rep,Nrep, ipdParams(c), angE);
                if any(~isfinite(lpIpd(:))), warning('IPD liklihood is not finite'); end
            end
            if ildParams(c).ildMode
                lpIld = messlIldLogLikelihood(W,T,I,Nt,C,rep,Nrep, ildParams(c), A);
                if any(~isfinite(lpIld(:))), warning('ILD liklihood is not finite'); end
            end
            if spParams(c).spMode
                lpSp = messlSpLogLikelihood(W,T,I,Nt,C,rep,Nrep, spParams(c), ...
                    ildParams(c), L, R);
                if any(~isfinite(lpSp(:))), warning('SP liklihood is not finite'); end
            end
            
            if useCombinedPost == 0
                % Combine binaural and GMM likelihoods and normalize:
                [ll(c,rep) p_lr_iwt nuIpd maskIpd nuIld maskIld nuSp maskSp] = ...
                    messlPosterior(W, T, I, Nt, C, logMaskPrior, ...
                    ipdParams(c).ipdMode, lpIpd, ildParams(c).ildMode, lpIld, ...
                    spParams(c).spMode, lpSp, vis || rep == Nrep, reliability, ...
                    mrfCompatPot, mrfCompatExpSched(min(end,rep)), mrfLbpIter);

                logMultichannelPosteriors(:,:,:,c) = single(log(squeeze(p_lr_iwt(1,:,:,:))));
            else
                % Subtract posteriors for current mic pair from
                % multi-channel posterior, use as "prior" for final mask
                % calculation.
                logCombinedMask = logMaskPrior + overcountRescale * ...
                    sum(logMultichannelPosteriors(:,:,:,setdiff(1:Np,c)), 4);

                % Combine binaural and GMM likelihoods and normalize:
                [ll(c,rep) p_lr_iwt nuIpd maskIpd nuIld maskIld nuSp maskSp] = ...
                    messlPosterior(W, T, I, Nt, C, logCombinedMask, ...
                    ipdParams(c).ipdMode, lpIpd, ildParams(c).ildMode, lpIld, ...
                    spParams(c).spMode, lpSp, vis || rep == Nrep, reliability, ...
                    mrfCompatPot, mrfCompatExpSched(min(end,rep)), mrfLbpIter);
                clear lp*

                % ll should be non-decreasing
                fprintf('%0.3e ', ll(c,rep));
                
                if (rep >= maskHold)
                    logMaskPrior = 0;
                end
                
                %%%% M step: use nu matrix to calcuate parameters
                nuIpd = messlIpdEnforcePriors(nuIpd, ipdParams(c));
                
                if ipdParams(c).ipdMode
                    ipdParams(c) = messlIpdUpdateParams(W, T, I, Nt, C, rep, ipdParams(c), ...
                        nuIpd, angE);
                end
                if ildParams(c).ildMode
                    ildParams(c) = messlIldUpdateParams(W, T, I, Nt, C, rep, ildParams(c), nuIld, ...
                        A, Nrep);
                end
                if spParams(c).spMode
                    spParams(c) = messlSpUpdateParams(W, T, I, Nt, C, rep, spParams(c), nuSp, ...
                        L, R, Nrep);
                end
            end
        end
    end
    fprintf('\n');
    
    subplots(cellFrom3D(mean(logMultichannelPosteriors,4)), [], [], @(r,c,i) caxis([-4 0]))
    drawnow
    
    if vis
        messlUtilVisualizeParams(W, T, I, tau, sr, ipdParams(c), ildParams(c), spParams(c), ...
            p_lr_iwt, maskIpd, maskIld, maskSp, L, R, reliability);
    end
end

% Compute per-mic TDOAs
pTauI = cat(3, ipdParams.p_tauI);
perPairTdoa = tau(squeeze(argmax(pTauI,2)))';   % posterior mode
% perPairTdoa = squeeze(sum(bsxfun(@times, tau, pTauI), 2) ./ sum(pTauI,2))';  % posterior mean
perMicTdoa = perMicTdoaLs(perPairTdoa(:,1:end-garbageSrc), channelPairs);

params = struct('ipdParams', ipdParams, 'ildParams', ildParams, ...
    'spParams', spParams, 'perMicTdoa', perMicTdoa, ...
    'channelPairs', channelPairs, 'tau', tau);

% Compute hard masks, potentially using the MRF model
[~,~,~,hardSrcs] = messlMrfApply(nuIld, nuIpd, p_lr_iwt, mrfCompatPot, mrfHardCompatExp, mrfLbpIter, 'max');
hardMasks = zeros(size(p_lr_iwt));
for i = 1:max(hardSrcs(:))
    hardMasks(:,:,:,i) = repmat(permute(hardSrcs == i, [3 1 2]), [2 1 1]);
end
